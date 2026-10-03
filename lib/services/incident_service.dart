import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/campus_locations.dart';
import '../data/demo_seed.dart';
import '../data/safety_guidance.dart';
import '../models/app_user.dart';
import '../models/campus_location.dart';
import '../models/dispatch.dart';
import '../models/enums.dart';
import '../models/incident.dart';
import '../models/responder.dart';
import '../models/timeline_event.dart';
import 'auth_service.dart';
import 'dispatch_service.dart';
import 'notification_service.dart';
import 'severity_service.dart';

/// Central incident store and workflow engine.
///
/// DEMO MODE backend: everything lives in memory and every change calls
/// [notifyListeners], so every open screen (student, responder, admin) updates
/// instantly without refreshing. A Firestore/RTDB adapter would replace the
/// in-memory maps with snapshot listeners while keeping these same methods.
class RescueStore extends ChangeNotifier {
  RescueStore({
    SeverityService? severity,
    DispatchService? dispatch,
    NotificationService? notifications,
    bool startTicker = true,
  })  : severity = severity ?? SeverityService(),
        dispatch = dispatch ?? DispatchService(),
        notifications = notifications ?? NotificationService() {
    auth = DemoAuthService(() => users.values);
    _seed();
    if (startTicker) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    }
  }

  final SeverityService severity;
  final DispatchService dispatch;
  final NotificationService notifications;
  late final AuthService auth;

  final Map<String, AppUser> users = {};
  final Map<String, Responder> responders = {};
  final List<Incident> incidents = [];
  final Map<String, List<TimelineEvent>> _timelines = {};
  List<CampusLocation> locations = [];

  DispatchWeights weights = DispatchWeights();
  int escalationTimeoutSec = 45;
  bool demoMode = true;
  bool simulateMovement = true;
  double simulationSpeed = 4; // x real time, demo only

  /// When no responder is AVAILABLE, queue the incident (by severity) instead
  /// of stacking it onto a busy responder.
  bool queueWhenBusy = true;

  /// Base wait (seconds) before the command center is warned that a queued
  /// incident needs external / off-duty help. CRITICAL uses half of this.
  int waitWarningSec = 120;
  List<ExternalContact> externalContacts = defaultExternalContacts();

  AppUser? currentUser;
  String? demoStep;
  bool demoRunning = false;

  int _incSeq = 1047;
  int _evSeq = 0;
  final Map<String, Timer> _escalationTimers = {};
  Timer? _ticker;
  bool _disposed = false;

  // ---------------------------------------------------------------- queries

  List<Incident> get activeIncidents => incidents.where((i) => i.isActive).toList();
  List<Incident> get resolvedIncidents => incidents.where((i) => !i.isActive).toList();

  Incident? incident(String id) {
    for (final i in incidents) {
      if (i.id == id) return i;
    }
    return null;
  }

  Responder? responderById(String? id) => id == null ? null : responders[id];

  Responder? responderForUser(String userId) {
    for (final r in responders.values) {
      if (r.userId == userId) return r;
    }
    return null;
  }

  CampusLocation? locationById(String id) {
    for (final l in locations) {
      if (l.id == id) return l;
    }
    return null;
  }

  List<TimelineEvent> timeline(String incidentId) => List.unmodifiable(_timelines[incidentId] ?? const []);

  List<TimelineEvent> get allEvents {
    final all = _timelines.values.expand((e) => e).toList();
    all.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return all;
  }

  /// Assignments waiting for this responder to accept/decline.
  List<Incident> pendingFor(String responderId) => incidents
      .where((i) => i.assignedResponderId == responderId && i.status == IncidentStatus.assigned)
      .toList();

  /// Accepted / in-progress incidents for this responder (primary or backup).
  List<Incident> activeFor(String responderId) => incidents
      .where((i) =>
          i.isActive &&
          ((i.assignedResponderId == responderId && i.status != IncidentStatus.assigned) ||
              i.backupResponderIds.contains(responderId)))
      .toList();

  List<Incident> historyFor(String responderId) => incidents
      .where((i) => !i.isActive && (i.assignedResponderId == responderId || i.backupResponderIds.contains(responderId)))
      .toList();

  List<Incident> reportedBy(String userId) => incidents.where((i) => i.reporterId == userId).toList();

  int unreadFor(AppUser? u) => notifications.forUser(u).where((n) => !n.read).length;

  Duration? get averageResponse {
    final times = incidents.map((i) => i.responseTime).whereType<Duration>().toList();
    if (times.isEmpty) return null;
    final s = times.fold<int>(0, (a, d) => a + d.inSeconds) ~/ times.length;
    return Duration(seconds: s);
  }

  Duration? get averageAssignment {
    final times = incidents.map((i) => i.assignmentTime).whereType<Duration>().toList();
    if (times.isEmpty) return null;
    final s = times.fold<int>(0, (a, d) => a + d.inSeconds) ~/ times.length;
    return Duration(seconds: s);
  }

  /// Queued incidents, highest severity first, then longest waiting.
  List<Incident> get queue {
    final q = incidents.where((i) => i.isQueued).toList();
    q.sort((a, b) {
      final c = b.severityScore.compareTo(a.severityScore);
      return c != 0 ? c : a.queuedAt!.compareTo(b.queuedAt!);
    });
    return q;
  }

  int queuePosition(Incident inc) => queue.indexWhere((i) => i.id == inc.id) + 1;

  int get freeResponderCount => responders.values.where((r) => r.status == ResponderStatus.available).length;

  Duration? get averageQueueWait {
    final w = incidents.where((i) => i.queuedAt != null && i.dequeuedAt != null).map((i) => i.queueWait!).toList();
    if (w.isEmpty) return null;
    return Duration(seconds: w.fold<int>(0, (a, d) => a + d.inSeconds) ~/ w.length);
  }

  int waitLimitFor(SeverityLevel l) => switch (l) {
        SeverityLevel.critical => waitWarningSec ~/ 2 < 30 ? 30 : waitWarningSec ~/ 2,
        SeverityLevel.high => waitWarningSec,
        SeverityLevel.medium => waitWarningSec * 2,
        SeverityLevel.low => waitWarningSec * 3,
      };

  // ---------------------------------------------------------------- auth

  String? login(String email, String password) {
    final invalid = DemoAuthService.validate(email, password);
    if (invalid != null) return invalid;
    final u = auth.signIn(email, password);
    if (u == null) return 'Invalid email or password.';
    currentUser = u;
    _changed();
    return null;
  }

  void logout() {
    currentUser = null;
    _changed();
  }

  bool get _isAdmin => currentUser?.role == UserRole.admin;

  void _requireAdmin() {
    // Admin-only controls. The demo orchestrator bypasses UI login by acting as
    // the system, so checks are skipped while it runs.
    if (!demoRunning && !_isAdmin) {
      throw StateError('Administrator permission required.');
    }
  }

  // ---------------------------------------------------------------- reporting

  Incident reportIncident({
    required AppUser reporter,
    required IncidentCategory category,
    required String description,
    required int peopleAffected,
    required CampusLocation location,
    GeoReading? gps,
    String? photoPath,
    bool demoPhoto = false,
    DateTime? at,
  }) {
    if (peopleAffected < 1) throw ArgumentError('peopleAffected must be >= 1');
    final now = at ?? DateTime.now();
    final cleanDescription = description.trim().length > 500 ? description.trim().substring(0, 500) : description.trim();
    final sev = severity.assess(
      category: category,
      description: cleanDescription,
      peopleAffected: peopleAffected,
      at: now,
      location: location,
    );
    final inc = Incident(
      id: 'INC-${_incSeq++}',
      reporterId: reporter.id,
      reporterName: reporter.name,
      category: category,
      description: cleanDescription,
      locationId: location.id,
      locationName: location.name,
      x: location.x,
      y: location.y,
      peopleAffected: peopleAffected,
      severity: sev,
      createdAt: now,
      gps: gps,
      photoPath: photoPath,
      demoPhoto: demoPhoto,
    );
    incidents.insert(0, inc);

    _event(inc, TimelineType.reported, 'Emergency reported by ${reporter.name} — ${category.label} at ${location.name}',
        actor: reporter.id, at: now);
    if (gps != null && gps.isReal) {
      _event(inc, TimelineType.gps,
          'GPS location captured (${gps.latitude.toStringAsFixed(5)}, ${gps.longitude.toStringAsFixed(5)} ±${gps.accuracy.round()} m)',
          at: now);
    } else {
      _event(inc, TimelineType.gps, 'Location set to ${location.name} (SIMULATED CAMPUS LOCATION — device GPS not used)', at: now);
    }
    if (photoPath != null || demoPhoto) {
      _event(inc, TimelineType.photo, demoPhoto ? 'Photo attached (demo placeholder)' : 'Photo attached', at: now);
    }
    _event(inc, TimelineType.severity, 'Severity calculated: ${sev.level.label} — ${sev.score}/100', at: now);

    notifications.deliver(
      title: '${category.emoji} New ${sev.level.label} incident ${inc.id}',
      body: '${category.label} reported at ${location.name}.',
      toRole: UserRole.admin,
      incidentId: inc.id,
      critical: sev.level == SeverityLevel.critical,
    );
    _autoDispatch(inc);
    _changed();
    return inc;
  }

  // ---------------------------------------------------------------- dispatch

  List<RankedResponder> rankFor(Incident inc) => dispatch.rank(
        incident: inc,
        responders: responders.values,
        weights: weights,
        exclude: inc.declinedBy,
      );

  void _autoDispatch(Incident inc) {
    final ranking = rankFor(inc);
    inc.lastRanking = ranking;
    final eligible = ranking.where((r) => r.eligible).toList();
    final free = eligible.where((r) => r.responder.status == ResponderStatus.available).toList();
    final pick = free.isNotEmpty ? free.first : (!queueWhenBusy && eligible.isNotEmpty ? eligible.first : null);
    if (pick == null) {
      _event(
          inc,
          TimelineType.ranking,
          eligible.isEmpty
              ? 'Responder ranking completed — no eligible responder on duty'
              : 'Responder ranking completed — all ${eligible.length} eligible responders are busy');
      _enqueue(inc);
      return;
    }
    _event(inc, TimelineType.ranking,
        'Responder ranking completed — ${pick.responder.name} recommended (score ${pick.total.round()}, skill ${(pick.skillMatch * 100).round()}%, ETA ${(pick.etaSec / 60).ceil()} min)');
    _assign(inc, pick.responder, manual: false);
  }

  // ---------------------------------------------------------------- queue

  void _enqueue(Incident inc, {String reason = 'All responders busy'}) {
    inc.assignedResponderId = null;
    inc.trackingActive = false;
    inc.status = IncidentStatus.reported;
    if (!inc.isQueued) {
      inc.queuedAt = DateTime.now();
      inc.dequeuedAt = null;
      inc.waitWarningRaised = false;
    }
    final pos = queuePosition(inc);
    final total = queue.length;
    _event(inc, TimelineType.queued, '$reason — queued at position $pos of $total (ordered by severity)');
    notifications.deliver(
      title: '⚠ NO RESPONDERS FREE',
      body: '${inc.id} (${inc.severityLevel.label} ${inc.severityScore}) queued #$pos — $total incident(s) waiting.',
      toRole: UserRole.admin,
      incidentId: inc.id,
      critical: true,
    );
    notifications.deliver(
      title: 'All responders are busy',
      body: 'No responders are currently available. The command center has been notified. '
          'You are #$pos in the queue — follow the safety steps on screen.',
      toUser: inc.reporterId,
      incidentId: inc.id,
    );
    final p = preemptionFor(inc);
    if (p != null) {
      _event(inc, TimelineType.note,
          'Recommendation: redirect ${p.responder.name} from lower-priority ${p.from.id} (${p.from.severityLevel.label} ${p.from.severityScore})');
      notifications.deliver(
        title: '↪ Redirect recommended for ${inc.id}',
        body: '${p.responder.name} is on lower-priority ${p.from.id}. Approve redirect in the queue panel.',
        toRole: UserRole.admin,
        incidentId: inc.id,
        critical: true,
      );
    }
  }

  /// Gives freed responders to queued incidents in priority order.
  void _drainQueue() {
    for (var guard = 0; guard < 25; guard++) {
      final q = queue;
      if (q.isEmpty) return;
      var assigned = false;
      for (final inc in q) {
        final ranking = rankFor(inc);
        final free =
            ranking.where((r) => r.eligible && r.responder.status == ResponderStatus.available).toList();
        if (free.isEmpty) continue;
        inc.lastRanking = ranking;
        _event(inc, TimelineType.ranking,
            '${free.first.responder.name} became free — auto-assigned from queue (score ${free.first.total.round()})');
        _assign(inc, free.first.responder, manual: false);
        assigned = true;
        break;
      }
      if (!assigned) return;
    }
  }

  /// For a queued CRITICAL incident: a suitable responder currently on a
  /// LOW/MEDIUM incident (not yet treating a patient) who could be redirected.
  ({Responder responder, Incident from})? preemptionFor(Incident inc) {
    if (!inc.isQueued || inc.severityLevel != SeverityLevel.critical) return null;
    ({Responder responder, Incident from})? best;
    var bestScore = -1.0;
    for (final rr in rankFor(inc)) {
      if (!rr.eligible || rr.skillMatch < 0.6) continue;
      for (final from in incidents) {
        if (from.id == inc.id || !from.isActive || from.assignedResponderId != rr.responder.id) continue;
        if (from.severityLevel.index > SeverityLevel.medium.index || from.severityScore >= inc.severityScore) continue;
        if (from.status == IncidentStatus.arrived || from.status == IncidentStatus.onScene) continue;
        if (rr.total > bestScore) {
          bestScore = rr.total;
          best = (responder: rr.responder, from: from);
        }
      }
    }
    return best;
  }

  /// Admin-approved: move a responder off a lower-priority incident onto a
  /// queued critical one. The lower-priority incident returns to the queue.
  void redirectResponder(String incidentId) {
    _requireAdmin();
    final inc = _get(incidentId);
    final p = preemptionFor(inc);
    if (p == null) throw StateError('No lower-priority responder can be redirected.');
    final r = p.responder;
    final from = p.from;
    _cancelEscalation(from.id);
    from.assignedResponderId = null;
    from.trackingActive = false;
    from.status = IncidentStatus.reported;
    _release(r, from);
    _event(from, TimelineType.preempted, '${r.name} redirected to CRITICAL ${inc.id} — this incident returns to the queue');
    notifications.deliver(
      title: 'Responder redirected',
      body: 'Your responder was redirected to a critical emergency. You are back in the queue.',
      toUser: from.reporterId,
      incidentId: from.id,
    );
    _event(inc, TimelineType.preempted,
        '${r.name} redirected from lower-priority ${from.id} (${from.severityLevel.label} ${from.severityScore}) — approved by command center',
        actor: currentUser?.id);
    notifications.deliver(
      title: '↪ Redirected to CRITICAL ${inc.id}',
      body: 'Leave ${from.id}. Go to ${inc.category.label} at ${inc.locationName}.',
      toUser: r.userId,
      incidentId: inc.id,
      critical: true,
    );
    _assign(inc, r, manual: true);
    _enqueue(from, reason: 'Responder redirected to a critical incident');
    _changed();
  }

  /// Notifies off-duty responders that they are needed. Returns how many.
  int alertOffDuty(String incidentId) {
    _requireAdmin();
    final inc = _get(incidentId);
    final off = responders.values.where((r) => r.status == ResponderStatus.offDuty).toList();
    for (final r in off) {
      notifications.deliver(
        title: '🚨 URGENT — all responders busy',
        body: '${inc.category.label} at ${inc.locationName} (${inc.severityLevel.label}). Go ON DUTY to take it.',
        toUser: r.userId,
        incidentId: inc.id,
        critical: true,
      );
    }
    inc.offDutyAlerted = true;
    _event(
        inc,
        TimelineType.offDutyAlert,
        off.isEmpty
            ? 'Off-duty check: no off-duty responders available to call in'
            : 'Off-duty alert sent to ${off.map((r) => r.name).join(', ')}',
        actor: currentUser?.id);
    _changed();
    return off.length;
  }

  /// Records that the command center contacted an external service.
  void logExternalHelp(String incidentId, String service) {
    _requireAdmin();
    final inc = _get(incidentId);
    inc.externalHelp.add(service);
    _event(inc, TimelineType.externalHelp, 'External help requested: $service', actor: currentUser?.id);
    notifications.deliver(
      title: 'External help contacted',
      body: '$service has been contacted for your emergency ${inc.id}.',
      toUser: inc.reporterId,
      incidentId: inc.id,
    );
    _changed();
  }

  void _assign(Incident inc, Responder r, {required bool manual}) {
    final prev = responderById(inc.assignedResponderId);
    if (prev != null && prev.id != r.id) _release(prev, inc);

    if (inc.isQueued) {
      inc.dequeuedAt = DateTime.now();
      final w = inc.queueWait!.inSeconds;
      _event(inc, TimelineType.dequeued,
          'Left queue after ${(w ~/ 60).toString().padLeft(2, '0')}:${(w % 60).toString().padLeft(2, '0')}');
    }
    inc.assignedResponderId = r.id;
    inc.status = IncidentStatus.assigned;
    inc.assignedAt ??= DateTime.now();
    inc.distanceM = DispatchService.distance(r.x, r.y, inc.x, inc.y);
    inc.etaSec = DispatchService.etaFor(inc.distanceM);
    inc.trackingActive = false;
    r.workload += 1;
    r.currentIncidentId ??= inc.id;
    // Pending acceptance counts as busy so the same responder is not handed
    // a second incident before answering the first.
    if (r.status == ResponderStatus.available) r.status = ResponderStatus.busy;
    r.lastUpdated = DateTime.now();

    _event(inc, TimelineType.assigned,
        manual ? '${r.name} manually assigned by command center' : '${r.name} automatically assigned',
        actor: manual ? currentUser?.id : 'system');
    notifications.deliver(
      title: '🚨 New Emergency Assignment',
      body: '${inc.category.label} reported at ${inc.locationName}. ETA: ${(inc.etaSec / 60).ceil()} minutes.',
      toUser: r.userId,
      incidentId: inc.id,
      critical: true,
    );
    _event(inc, TimelineType.notified, 'Assignment notification sent to ${r.name}');
    notifications.deliver(
      title: 'Responder assigned',
      body: '${r.name} has been assigned to your report ${inc.id}.',
      toUser: inc.reporterId,
      incidentId: inc.id,
    );
    _startEscalationTimer(inc);
  }

  void _release(Responder r, Incident inc) {
    if (r.workload > 0) r.workload -= 1;
    if (r.currentIncidentId == inc.id) {
      final other = incidents.where((i) =>
          i.id != inc.id &&
          i.isActive &&
          (i.assignedResponderId == r.id || i.backupResponderIds.contains(r.id)));
      r.currentIncidentId = other.isEmpty ? null : other.first.id;
    }
    if (r.status != ResponderStatus.offDuty) {
      r.status = r.workload == 0 ? ResponderStatus.available : ResponderStatus.busy;
    }
    r.lastUpdated = DateTime.now();
  }

  void _startEscalationTimer(Incident inc) {
    _escalationTimers.remove(inc.id)?.cancel();
    if (escalationTimeoutSec <= 0) return;
    final assigned = inc.assignedResponderId;
    _escalationTimers[inc.id] = Timer(Duration(seconds: escalationTimeoutSec), () {
      if (_disposed) return;
      if (inc.status == IncidentStatus.assigned && inc.assignedResponderId == assigned) {
        escalate(inc.id, reason: 'Responder did not accept assignment within ${escalationTimeoutSec}s', system: true);
      }
    });
  }

  void _cancelEscalation(String id) => _escalationTimers.remove(id)?.cancel();

  // ---------------------------------------------------------------- responder actions

  Incident _get(String id) {
    final i = incident(id);
    if (i == null) throw StateError('Unknown incident $id');
    return i;
  }

  void accept(String incidentId) {
    final inc = _get(incidentId);
    final r = responderById(inc.assignedResponderId);
    if (r == null || inc.status != IncidentStatus.assigned) return;
    _cancelEscalation(inc.id);
    inc.status = IncidentStatus.accepted;
    inc.acceptedAt = DateTime.now();
    r.status = ResponderStatus.busy;
    r.currentIncidentId = inc.id;
    _event(inc, TimelineType.accepted, 'Assignment accepted by ${r.name}', actor: r.userId);
    notifications.deliver(
        title: '✓ Assignment Accepted', body: '${r.name} accepted the emergency.', toUser: inc.reporterId, incidentId: inc.id);
    notifications.deliver(
        title: '✓ Assignment Accepted', body: '${r.name} accepted ${inc.id}.', toRole: UserRole.admin, incidentId: inc.id);
    _changed();
  }

  void decline(String incidentId, String reason) {
    final inc = _get(incidentId);
    final r = responderById(inc.assignedResponderId);
    if (r == null || inc.status != IncidentStatus.assigned) return;
    _cancelEscalation(inc.id);
    inc.declinedBy.add(r.id);
    _release(r, inc);
    if (reason == 'Off duty') r.status = ResponderStatus.offDuty;
    inc.assignedResponderId = null;
    inc.status = IncidentStatus.reported;
    _event(inc, TimelineType.declined, 'Assignment declined by ${r.name} — reason: $reason', actor: r.userId);
    notifications.deliver(
      title: 'Assignment declined',
      body: '${r.name} declined ${inc.id} ($reason). Re-ranking responders.',
      toRole: UserRole.admin,
      incidentId: inc.id,
    );
    _autoDispatch(inc);
    _drainQueue();
    _changed();
  }

  void startRoute(String incidentId) {
    final inc = _get(incidentId);
    final r = responderById(inc.assignedResponderId);
    if (r == null || inc.status != IncidentStatus.accepted) return;
    inc.status = IncidentStatus.enRoute;
    inc.trackingActive = true;
    r.status = ResponderStatus.enRoute;
    _updateTracking(inc, r);
    _event(inc, TimelineType.enRoute, '${r.name} en route — ${(inc.distanceM).round()} m, ETA ${(inc.etaSec / 60).ceil()} min',
        actor: r.userId);
    final body = '${r.name} is traveling to the incident. ETA: ${(inc.etaSec / 60).ceil().toString().padLeft(2, '0')} minutes.';
    notifications.deliver(title: '🚗 Responder En Route', body: body, toUser: inc.reporterId, incidentId: inc.id);
    notifications.deliver(title: '🚗 Responder En Route', body: '$body (${inc.id})', toRole: UserRole.admin, incidentId: inc.id);
    _changed();
  }

  void markArrived(String incidentId, {bool auto = false}) {
    final inc = _get(incidentId);
    final r = responderById(inc.assignedResponderId);
    if (r == null || (inc.status != IncidentStatus.enRoute && inc.status != IncidentStatus.accepted)) return;
    inc.status = IncidentStatus.arrived;
    inc.arrivedAt = DateTime.now();
    inc.trackingActive = false;
    inc.etaSec = 0;
    inc.distanceM = 0;
    r.x = inc.x;
    r.y = inc.y;
    r.status = ResponderStatus.onScene;
    _event(inc, TimelineType.arrived, auto ? '${r.name} arrived (detected by live tracking)' : '${r.name} arrived',
        actor: r.userId);
    notifications.deliver(title: '📍 Responder Arrived', body: '${r.name} has arrived.', toUser: inc.reporterId, incidentId: inc.id);
    notifications.deliver(
        title: '📍 Responder Arrived', body: '${r.name} arrived at ${inc.locationName} (${inc.id}).', toRole: UserRole.admin, incidentId: inc.id);
    _changed();
  }

  void markOnScene(String incidentId) {
    final inc = _get(incidentId);
    final r = responderById(inc.assignedResponderId);
    if (r == null || inc.status != IncidentStatus.arrived) return;
    inc.status = IncidentStatus.onScene;
    r.status = ResponderStatus.onScene;
    _event(inc, TimelineType.onScene, '${r.name} on scene — treatment / containment in progress', actor: r.userId);
    _changed();
  }

  void requestBackup(String incidentId, List<String> reasons) {
    final inc = _get(incidentId);
    if (!inc.isActive) return;
    inc.backupRequested = true;
    inc.backupReasons = reasons.isEmpty ? const ['Other'] : List.unmodifiable(reasons);
    final requester = responderById(inc.assignedResponderId);
    _event(inc, TimelineType.backupRequested,
        'Backup requested${requester != null ? ' by ${requester.name}' : ''}: ${inc.backupReasons.join(', ')}',
        actor: requester?.userId);

    // Raise priority.
    final loc = locationById(inc.locationId);
    if (loc != null) {
      final before = inc.severity.level;
      inc.severity = severity.assess(
        category: inc.category,
        description: inc.description,
        peopleAffected: inc.peopleAffected,
        at: inc.createdAt,
        location: loc,
        priorityBoost: 5,
      );
      _event(inc, TimelineType.priority,
          'Priority raised: ${inc.severity.level.label} — ${inc.severity.score}/100${before != inc.severity.level ? ' (was ${before.label})' : ''}');
    }

    final ranking = rankFor(inc).where((r) => r.eligible).toList();
    inc.recommendedBackupId = ranking.isEmpty ? null : ranking.first.responder.id;
    final rec = responderById(inc.recommendedBackupId);
    notifications.deliver(
      title: '⚠ ESCALATION — Backup requested',
      body: '${inc.id} at ${inc.locationName}: ${inc.backupReasons.join(', ')}. '
          '${rec != null ? 'Recommended backup: ${rec.name}.' : 'No backup currently available.'}',
      toRole: UserRole.admin,
      incidentId: inc.id,
      critical: true,
    );
    _changed();
  }

  // ---------------------------------------------------------------- admin actions

  void manualAssign(String incidentId, String responderId) {
    _requireAdmin();
    final inc = _get(incidentId);
    final r = responderById(responderId);
    if (r == null || !inc.isActive) return;
    inc.declinedBy.remove(r.id);
    inc.escalated = false;
    _assign(inc, r, manual: true);
    _changed();
  }

  void assignBackup(String incidentId, String responderId) {
    _requireAdmin();
    final inc = _get(incidentId);
    final r = responderById(responderId);
    if (r == null || !inc.isActive || inc.backupResponderIds.contains(r.id) || inc.assignedResponderId == r.id) return;
    inc.backupResponderIds.add(r.id);
    inc.recommendedBackupId = null;
    r.workload += 1;
    r.currentIncidentId ??= inc.id;
    r.status = ResponderStatus.enRoute;
    _event(inc, TimelineType.backupAssigned, 'Backup assigned: ${r.name} (${r.type})', actor: currentUser?.id);
    notifications.deliver(
      title: '🚨 Backup Assignment',
      body: 'Support ${inc.id} — ${inc.category.label} at ${inc.locationName}.',
      toUser: r.userId,
      incidentId: inc.id,
      critical: true,
    );
    notifications.deliver(
        title: 'Backup on the way', body: '${r.name} is joining the response.', toUser: inc.reporterId, incidentId: inc.id);
    _changed();
  }

  void escalate(String incidentId, {required String reason, bool system = false}) {
    if (!system) _requireAdmin();
    final inc = _get(incidentId);
    if (!inc.isActive) return;
    _cancelEscalation(inc.id);
    final r = responderById(inc.assignedResponderId);
    inc.escalated = true;
    if (r != null && inc.status == IncidentStatus.assigned) {
      inc.declinedBy.add(r.id);
      _release(r, inc);
      inc.assignedResponderId = null;
      inc.status = IncidentStatus.reported;
      _event(inc, TimelineType.escalated, 'ESCALATING INCIDENT — ${r.name} → No response. $reason');
    } else {
      _event(inc, TimelineType.escalated, 'Incident escalated: $reason', actor: system ? 'system' : currentUser?.id);
    }
    notifications.deliver(
      title: '⚠ ESCALATION REQUIRED',
      body: 'Incident ${inc.id}. Reason: $reason. Action: next responder recommended.',
      toRole: UserRole.admin,
      incidentId: inc.id,
      critical: true,
    );
    if (inc.assignedResponderId == null && !inc.isQueued) _autoDispatch(inc);
    _drainQueue();
    _changed();
  }

  void resolve(String incidentId) {
    final inc = _get(incidentId);
    if (!inc.isActive) return;
    final actor = currentUser;
    final primary = responderById(inc.assignedResponderId);
    final isAssignedResponder = actor != null && primary != null && primary.userId == actor.id;
    if (!demoRunning && !_isAdmin && !isAssignedResponder) {
      throw StateError('Only the assigned responder or an administrator can resolve.');
    }
    _cancelEscalation(inc.id);
    inc.status = IncidentStatus.resolved;
    inc.resolvedAt = DateTime.now();
    inc.arrivedAt ??= inc.resolvedAt;
    inc.trackingActive = false;
    inc.escalated = false;
    for (final id in [inc.assignedResponderId, ...inc.backupResponderIds]) {
      final r = responderById(id);
      if (r != null) {
        _release(r, inc);
        r.resolvedToday += 1;
      }
    }
    _event(inc, TimelineType.resolved, 'Incident resolved${actor != null ? ' by ${actor.name}' : ''}', actor: actor?.id);
    _event(inc, TimelineType.archived, 'Timeline completed — incident archived');
    for (final target in [inc.reporterId]) {
      notifications.deliver(
          title: '✓ Incident Resolved', body: 'Incident ${inc.id} has been resolved.', toUser: target, incidentId: inc.id);
    }
    notifications.deliver(
        title: '✓ Incident Resolved', body: 'Incident ${inc.id} has been resolved.', toRole: UserRole.admin, incidentId: inc.id);
    _drainQueue();
    _changed();
  }

  void setDuty(String responderId, bool onDuty) {
    final r = responderById(responderId);
    if (r == null) return;
    r.status = onDuty ? (r.workload > 0 ? ResponderStatus.busy : ResponderStatus.available) : ResponderStatus.offDuty;
    r.lastUpdated = DateTime.now();
    if (onDuty) _drainQueue();
    _changed();
  }

  void addNote(String incidentId, String text) {
    final inc = _get(incidentId);
    if (text.trim().isEmpty) return;
    _event(inc, TimelineType.note, text.trim(), actor: currentUser?.id);
    _changed();
  }

  // ---------------------------------------------------------------- settings

  void updateSettings(VoidCallback change) {
    change();
    _changed();
  }

  void addLocation(String name, int risk) {
    final id = 'loc_${DateTime.now().millisecondsSinceEpoch}';
    locations.add(CampusLocation(id: id, name: name.trim(), x: 500, y: 300, risk: risk < 0 ? 0 : (risk > 10 ? 10 : risk)));
    _changed();
  }

  void removeLocation(String id) {
    if (incidents.any((i) => i.locationId == id && i.isActive)) return;
    locations.removeWhere((l) => l.id == id);
    _changed();
  }

  // ---------------------------------------------------------------- live tracking

  void _updateTracking(Incident inc, Responder r) {
    inc.distanceM = DispatchService.distance(r.x, r.y, inc.x, inc.y);
    inc.etaSec = (inc.distanceM / DispatchService.speedMps).round();
  }

  /// Advances simulated responder movement. Called every second.
  @visibleForTesting
  void tick() {
    if (_disposed) return;
    var changed = false;
    final step = DispatchService.speedMps * simulationSpeed;
    for (final inc in simulateMovement ? incidents.toList() : const <Incident>[]) {
      if (!inc.isActive) continue;
      // Primary responder
      final r = responderById(inc.assignedResponderId);
      if (r != null && inc.trackingActive && inc.status == IncidentStatus.enRoute) {
        if (_moveToward(r, inc.x, inc.y, step)) {
          markArrived(inc.id, auto: true);
        } else {
          _updateTracking(inc, r);
        }
        changed = true;
      }
      // Backup responders
      for (final id in inc.backupResponderIds) {
        final b = responderById(id);
        if (b != null && b.status == ResponderStatus.enRoute) {
          if (_moveToward(b, inc.x + 14, inc.y + 10, step)) {
            b.status = ResponderStatus.onScene;
            _event(inc, TimelineType.backupArrived, 'Backup ${b.name} arrived on scene');
          }
          changed = true;
        }
      }
    }
    // Queue: live wait timers, wait warnings, and auto-assign when free.
    final q = queue;
    if (q.isNotEmpty) {
      changed = true;
      final now = DateTime.now();
      for (final inc in q) {
        final limit = waitLimitFor(inc.severityLevel);
        if (!inc.waitWarningRaised && now.difference(inc.queuedAt!).inSeconds >= limit) {
          inc.waitWarningRaised = true;
          _event(inc, TimelineType.waitWarning,
              'Waiting over ${limit}s with no free responder — call external help or off-duty responders');
          notifications.deliver(
            title: '⏱ ${inc.id} waiting too long',
            body: '${inc.severityLevel.label} incident queued over ${limit}s. Consider external help.',
            toRole: UserRole.admin,
            incidentId: inc.id,
            critical: true,
          );
        }
      }
      if (freeResponderCount > 0) _drainQueue();
    }
    if (changed) _changed();
  }

  /// Returns true when the responder reached the target.
  bool _moveToward(Responder r, double tx, double ty, double step) {
    final d = DispatchService.distance(r.x, r.y, tx, ty);
    if (d <= step || d < 6) {
      r.x = tx;
      r.y = ty;
      r.lastUpdated = DateTime.now();
      return true;
    }
    r.x += (tx - r.x) / d * step;
    r.y += (ty - r.y) / d * step;
    r.lastUpdated = DateTime.now();
    return false;
  }

  // ---------------------------------------------------------------- timeline

  void _event(Incident inc, TimelineType type, String message, {String? actor, DateTime? at}) {
    final e = TimelineEvent(
      id: 'E${++_evSeq}',
      incidentId: inc.id,
      type: type,
      message: message,
      timestamp: at ?? DateTime.now(),
      actorId: actor,
    );
    (_timelines[inc.id] ??= []).add(e);
  }

  // ---------------------------------------------------------------- demo data

  void resetDemo() {
    for (final t in _escalationTimers.values) {
      t.cancel();
    }
    _escalationTimers.clear();
    final keepUser = currentUser?.id;
    _seed();
    currentUser = keepUser == null ? null : users[keepUser];
    demoStep = null;
    _changed();
  }

  void _seed() {
    users
      ..clear()
      ..addEntries(DemoSeed.users().map((u) => MapEntry(u.id, u)));
    responders
      ..clear()
      ..addEntries(DemoSeed.responders().map((r) => MapEntry(r.id, r)));
    incidents.clear();
    _timelines.clear();
    notifications.clear();
    locations = defaultCampusLocations();
    _incSeq = 1042;
    _evSeq = 0;
    _seedHistory();
    _seedActive();
    _incSeq = 1047;
  }

  /// Resolved incidents from earlier today / this week so analytics has data.
  void _seedHistory() {
    final now = DateTime.now();
    final history = <(IncidentCategory, String, int, String, int, int, String)>[
      // category, locationId, people, desc, minutesAgo, responseMin, responderId
      (IncidentCategory.medical, 'canteen', 1, 'Student fainted in queue', 95, 4, 'R01'),
      (IncidentCategory.electrical, 'eee', 1, 'Spark from lab socket', 180, 5, 'R04'),
      (IncidentCategory.security, 'parking', 2, 'Unknown person near vehicles', 260, 3, 'R02'),
      (IncidentCategory.accident, 'sports', 1, 'Player injured, possible fracture', 60 * 26, 6, 'R01'),
      (IncidentCategory.fire, 'workshop', 3, 'Smoke from grinder area', 60 * 30, 3, 'R03'),
      (IncidentCategory.flooding, 'hostel', 4, 'Water leak flooding corridor', 60 * 50, 7, 'R05'),
      (IncidentCategory.medical, 'library', 1, 'Dizzy, chest pain', 60 * 75, 4, 'R01'),
      (IncidentCategory.other, 'auditorium', 5, 'Crowd panic after event', 60 * 100, 5, 'R05'),
    ];
    var seq = 1000;
    for (final h in history) {
      final loc = locationById(h.$2)!;
      final created = now.subtract(Duration(minutes: h.$5));
      final sev = severity.assess(
          category: h.$1, description: h.$4, peopleAffected: h.$3, at: created, location: loc);
      final inc = Incident(
        id: 'INC-${seq++}',
        reporterId: 'student0${(seq % 9) + 1}',
        reporterName: 'Student 0${(seq % 9) + 1}',
        category: h.$1,
        description: h.$4,
        locationId: loc.id,
        locationName: loc.name,
        x: loc.x,
        y: loc.y,
        peopleAffected: h.$3,
        severity: sev,
        createdAt: created,
        isSeed: true,
      );
      final r = responders[h.$7]!;
      inc.assignedResponderId = r.id;
      inc.assignedAt = created.add(const Duration(seconds: 20));
      inc.acceptedAt = created.add(const Duration(seconds: 50));
      inc.arrivedAt = created.add(Duration(minutes: h.$6));
      inc.resolvedAt = created.add(Duration(minutes: h.$6 + 12));
      inc.status = IncidentStatus.resolved;
      _event(inc, TimelineType.reported, 'Emergency reported by ${inc.reporterName}', at: created);
      _event(inc, TimelineType.severity, 'Severity calculated: ${sev.level.label} — ${sev.score}/100', at: created);
      _event(inc, TimelineType.assigned, '${r.name} automatically assigned', at: inc.assignedAt);
      _event(inc, TimelineType.accepted, 'Assignment accepted by ${r.name}', at: inc.acceptedAt);
      _event(inc, TimelineType.arrived, '${r.name} arrived', at: inc.arrivedAt);
      _event(inc, TimelineType.resolved, 'Incident resolved by ${r.name}', at: inc.resolvedAt);
      _event(inc, TimelineType.archived, 'Timeline completed — incident archived', at: inc.resolvedAt);
      incidents.add(inc);
    }
  }

  /// Simulated active incidents INC-1042..INC-1046 (not real incidents).
  void _seedActive() {
    final now = DateTime.now();
    Incident make(IncidentCategory c, String locId, int people, String desc, String reporter, int minutesAgo) {
      final loc = locationById(locId)!;
      final created = now.subtract(Duration(minutes: minutesAgo));
      final sev = severity.assess(category: c, description: desc, peopleAffected: people, at: created, location: loc);
      final inc = Incident(
        id: 'INC-${_incSeq++}',
        reporterId: reporter,
        reporterName: users[reporter]?.name ?? reporter,
        category: c,
        description: desc,
        locationId: loc.id,
        locationName: loc.name,
        x: loc.x,
        y: loc.y,
        peopleAffected: people,
        severity: sev,
        createdAt: created,
        isSeed: true,
      );
      _event(inc, TimelineType.reported, 'Emergency reported by ${inc.reporterName} — ${c.label} at ${loc.name}', at: created);
      _event(inc, TimelineType.gps, 'Location set to ${loc.name} (SIMULATED CAMPUS LOCATION)', at: created);
      _event(inc, TimelineType.severity, 'Severity calculated: ${sev.level.label} — ${sev.score}/100', at: created);
      incidents.insert(0, inc);
      return inc;
    }

    void assignSeed(Incident inc, String rid, IncidentStatus status, int minutesAgo) {
      final r = responders[rid]!;
      final t = now.subtract(Duration(minutes: minutesAgo));
      inc.assignedResponderId = r.id;
      inc.assignedAt = t;
      inc.status = status;
      inc.distanceM = DispatchService.distance(r.x, r.y, inc.x, inc.y);
      inc.etaSec = DispatchService.etaFor(inc.distanceM);
      r.workload += 1;
      r.currentIncidentId = inc.id;
      _event(inc, TimelineType.ranking, 'Responder ranking completed — ${r.name} recommended', at: t);
      _event(inc, TimelineType.assigned, '${r.name} automatically assigned', at: t);
      if (status.index >= IncidentStatus.accepted.index) {
        inc.acceptedAt = t.add(const Duration(seconds: 40));
        _event(inc, TimelineType.accepted, 'Assignment accepted by ${r.name}', at: inc.acceptedAt);
        r.status = ResponderStatus.busy;
      }
      if (status.index >= IncidentStatus.enRoute.index) {
        _event(inc, TimelineType.enRoute, '${r.name} en route', at: t.add(const Duration(minutes: 1)));
        r.status = ResponderStatus.enRoute;
      }
      if (status.index >= IncidentStatus.arrived.index) {
        inc.arrivedAt = t.add(const Duration(minutes: 3));
        _event(inc, TimelineType.arrived, '${r.name} arrived', at: inc.arrivedAt);
        r.status = ResponderStatus.onScene;
        r.x = inc.x + 20;
        r.y = inc.y + 20;
      }
    }

    final i42 = make(IncidentCategory.medical, 'cse', 2, 'Student collapsed during lab session', 'student04', 9);
    assignSeed(i42, 'R05', IncidentStatus.enRoute, 8);
    final i43 = make(IncidentCategory.electrical, 'ece_lab', 3, 'Sparks and burning smell from panel', 'student03', 7);
    assignSeed(i43, 'R04', IncidentStatus.onScene, 6);
    final i44 = make(IncidentCategory.security, 'main_gate', 4, 'Person with knife threatening students', 'student06', 5);
    assignSeed(i44, 'R02', IncidentStatus.enRoute, 4);
    final i45 = make(IncidentCategory.accident, 'parking', 2, 'Two-wheeler accident, rider bleeding', 'student07', 4);
    i45.status = IncidentStatus.reported;
    i45.escalated = true;
    _event(i45, TimelineType.escalated, 'Awaiting manual assignment (seeded escalation)');
    final i46 = make(IncidentCategory.fire, 'workshop', 5, 'Fire and heavy smoke near machines', 'student05', 2);
    assignSeed(i46, 'R03', IncidentStatus.accepted, 1);
  }

  // ---------------------------------------------------------------- plumbing

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    for (final t in _escalationTimers.values) {
      t.cancel();
    }
    notifications.dispose();
    super.dispose();
  }
}
