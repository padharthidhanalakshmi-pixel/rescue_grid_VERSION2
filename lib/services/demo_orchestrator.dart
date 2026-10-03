import 'dart:async';

import '../models/campus_location.dart';
import '../models/enums.dart';
import '../models/incident.dart';
import 'incident_service.dart';

/// Drives the full RescueGrid story end-to-end for judges:
/// report → GPS → photo → severity → ranking → assignment → notification →
/// accept → route → ETA updates → arrival → backup → escalation → backup
/// assigned → resolved → timeline completed.
///
/// Every step calls the same store methods the real UI uses; nothing is faked
/// except GPS (simulated campus location) and the photo (demo placeholder).
class DemoOrchestrator {
  DemoOrchestrator(this.store);
  final RescueStore store;
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  Future<void> _step(String text, [int ms = 1600]) async {
    if (_cancelled) throw _Cancelled();
    store.updateSettings(() => store.demoStep = text);
    await Future<void>.delayed(Duration(milliseconds: ms));
    if (_cancelled) throw _Cancelled();
  }

  Future<Incident?> run() async {
    if (store.demoRunning) return null;
    _cancelled = false;
    store.updateSettings(() {
      store.demoRunning = true;
      store.simulateMovement = true;
    });
    Incident? inc;
    try {
      final student = store.users['student01']!;
      final CampusLocation cse = store.locationById('cse') ?? store.locations.first;

      await _step('STEP 1 · Student 01 opens REPORT EMERGENCY');
      await _step('STEP 2 · Category: 🚑 Medical Emergency');
      await _step('STEP 3 · Location captured: CSE Department (simulated campus location)');
      await _step('STEP 4 · Photo attached (demo placeholder)');
      await _step('STEP 5 · “Student feeling unconscious near CSE Department” · 2 people');

      inc = store.reportIncident(
        reporter: student,
        category: IncidentCategory.medical,
        description: 'Student feeling unconscious near CSE Department',
        peopleAffected: 2,
        location: cse,
        demoPhoto: true,
      );
      final id = inc.id;
      await _step('STEP 6 · Severity Engine: ${inc.severityLevel.label} — ${inc.severityScore}/100', 2200);
      final top = inc.lastRanking.isEmpty ? null : inc.lastRanking.first;
      if (top != null) {
        await _step(
            'STEP 7 · Ranking: ${top.responder.name} · skill ${(top.skillMatch * 100).round()}% · ETA ${(top.etaSec / 60).ceil()} min',
            2200);
      }
      final assigned = store.responderById(inc.assignedResponderId);
      if (assigned == null) {
        await _step('No responders available — command center notified');
        return inc;
      }
      await _step('STEP 8 · Auto-assigned to ${assigned.name} · notification sent');
      await _step('STEP 9 · ${assigned.name} accepts the assignment');
      store.accept(id);
      await _step('STEP 10 · Navigation started · status EN ROUTE');
      store.startRoute(id);

      // Let live tracking run for a while so ETA visibly counts down.
      for (var i = 0; i < 4; i++) {
        final cur = store.incident(id)!;
        if (cur.status != IncidentStatus.enRoute) break;
        await _step('STEP 11 · Live tracking · ${cur.distanceM.round()} m · ETA ${_mmss(cur.etaSec)}', 1000);
      }

      await _step('STEP 12 · Responder requests BACKUP (crowd control)');
      store.requestBackup(id, ['Crowd control', 'Medical assistance']);
      final rec = store.incident(id)!.recommendedBackupId;
      await _step('STEP 13 · Command center receives escalation alert', 2000);
      if (rec != null) {
        store.assignBackup(id, rec);
        await _step('STEP 14 · Admin assigns backup: ${store.responderById(rec)?.name}');
      }

      // Wait for arrival (tracking) — force it if movement is slow.
      for (var i = 0; i < 20; i++) {
        final cur = store.incident(id)!;
        if (cur.status != IncidentStatus.enRoute) break;
        await _step('STEP 15 · En route · ${cur.distanceM.round()} m · ETA ${_mmss(cur.etaSec)}', 1000);
      }
      if (store.incident(id)!.status == IncidentStatus.enRoute) store.markArrived(id);
      await _step('STEP 16 · 📍 Responder ARRIVED');
      store.markOnScene(id);
      await _step('STEP 17 · Status ON SCENE — patient stabilised', 2200);
      store.resolve(id);
      await _step('STEP 18 · ✓ Incident RESOLVED · timeline completed & archived', 2600);
      return store.incident(id);
    } on _Cancelled {
      return inc;
    } finally {
      store.updateSettings(() {
        store.demoRunning = false;
        store.demoStep = null;
      });
    }
  }

  /// SCENARIO 2 — every responder is busy.
  /// Shows: queue by severity → critical jumps ahead → safety guidance →
  /// external help logged → redirect from a lower-priority job → off-duty
  /// check → a responder frees up → queue auto-assigns.
  Future<Incident?> runBusyScenario() async {
    if (store.demoRunning) return null;
    _cancelled = false;
    store.resetDemo();
    store.updateSettings(() {
      store.demoRunning = true;
      store.queueWhenBusy = true;
    });
    Incident? crit;
    try {
      CampusLocation loc(String id) => store.locationById(id) ?? store.locations.first;

      await _step('SCENARIO · ALL RESPONDERS BUSY — 4 of 5 responders are already on incidents');
      await _step('STEP 1 · Minor incident: water leak at the Library');
      final leak = store.reportIncident(
        reporter: store.users['student08']!,
        category: IncidentCategory.flooding,
        description: 'Water leak from the ceiling near the reading hall',
        peopleAffected: 1,
        location: loc('library'),
      );
      final r1 = store.responderById(leak.assignedResponderId);
      if (leak.status == IncidentStatus.assigned) store.accept(leak.id);
      await _step('STEP 2 · ${r1?.name ?? 'Last free responder'} takes ${leak.id} (${leak.severityLevel.label} ${leak.severityScore})', 2200);
      await _step('STEP 3 · Available responders: ${store.freeResponderCount} — EVERYONE IS BUSY', 2400);

      final fight = store.reportIncident(
        reporter: store.users['student06']!,
        category: IncidentCategory.security,
        description: 'Minor fight between two students near the canteen',
        peopleAffected: 2,
        location: loc('canteen'),
      );
      await _step(
          'STEP 4 · ${fight.id} ${fight.severityLevel.label} ${fight.severityScore} reported → no one free → QUEUED #${store.queuePosition(fight)}',
          2600);

      crit = store.reportIncident(
        reporter: store.users['student02']!,
        category: IncidentCategory.medical,
        description: 'Student collapsed and not breathing near the auditorium',
        peopleAffected: 3,
        location: loc('auditorium'),
        demoPhoto: true,
      );
      final cid = crit.id;
      await _step(
          'STEP 5 · CRITICAL $cid (${crit.severityScore}/100) jumps to QUEUE #${store.queuePosition(crit)} — ahead of ${fight.id}',
          2800);
      await _step('STEP 6 · Student 02 sees queue position + safety steps (stay with the person, check breathing)', 2400);

      store.logExternalHelp(cid, 'Ambulance (108)');
      await _step('STEP 7 · Command center logs external help: Ambulance (108) — demo only, no real call placed', 2600);

      final p = store.preemptionFor(store.incident(cid)!);
      if (p != null) {
        await _step(
            'STEP 8 · System recommends redirecting ${p.responder.name} from lower-priority ${p.from.id} (${p.from.severityLevel.label})',
            2800);
        store.redirectResponder(cid);
        await _step('STEP 9 · Admin approves → ${p.responder.name} redirected · ${p.from.id} goes back to the queue', 2600);
        store.accept(cid);
        store.startRoute(cid);
        await _step('STEP 10 · ${p.responder.name} accepts CRITICAL $cid · EN ROUTE', 2400);
      }

      final off = store.alertOffDuty(fight.id);
      await _step(
          off == 0
              ? 'STEP 11 · Off-duty check: nobody off duty to call in — external help is the fallback'
              : 'STEP 11 · $off off-duty responder(s) alerted',
          2400);

      final i43 = store.incident('INC-1043');
      if (i43 != null && i43.isActive) {
        final freed = store.responderById(i43.assignedResponderId)?.name ?? 'A responder';
        await _step('STEP 12 · $freed finishes INC-1043 …');
        store.resolve(i43.id);
        final got = store.activeIncidents.where((i) => i.assignedResponderId == 'R04').map((i) => i.id).join(', ');
        await _step('STEP 13 · $freed is free → queue AUTO-ASSIGNS top incident: ${got.isEmpty ? '—' : got}', 3000);
      }

      final q = store.queue;
      await _step(
          q.isEmpty
              ? 'DONE · Queue cleared — no emergency was dropped'
              : 'DONE · ${q.length} still queued (${q.map((i) => i.id).join(', ')}) — auto-assigns when the next responder is free',
          3600);
      return store.incident(cid);
    } on _Cancelled {
      return crit;
    } finally {
      store.updateSettings(() {
        store.demoRunning = false;
        store.demoStep = null;
      });
    }
  }

  static String _mmss(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

class _Cancelled implements Exception {}
