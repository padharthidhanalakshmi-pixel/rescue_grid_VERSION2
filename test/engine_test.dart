import 'package:flutter_test/flutter_test.dart';
import 'package:rescuegrid/data/campus_locations.dart';
import 'package:rescuegrid/models/enums.dart';
import 'package:rescuegrid/services/incident_service.dart';
import 'package:rescuegrid/services/severity_service.dart';

void main() {
  final cse = defaultCampusLocations().firstWhere((l) => l.id == 'cse');

  group('SeverityService', () {
    final s = SeverityService();

    test('demo scenario scores HIGH during class hours', () {
      final r = s.assess(
        category: IncidentCategory.medical,
        description: 'Student feeling unconscious near CSE Department',
        peopleAffected: 2,
        at: DateTime(2026, 10, 5, 10, 21),
        location: cse,
      );
      // 40 category + 18 keyword + 7 people + 5 time + 6 location
      expect(r.score, 76);
      expect(r.level, SeverityLevel.high);
      expect(r.reasons.any((x) => x.contains('unconscious')), isTrue);
    });

    test('score is capped at 100 and thresholds map correctly', () {
      final r = s.assess(
        category: IncidentCategory.fire,
        description: 'fire smoke explosion trapped',
        peopleAffected: 9,
        at: DateTime(2026, 10, 5, 23),
        location: cse,
        priorityBoost: 20,
      );
      expect(r.score, 100);
      expect(r.level, SeverityLevel.critical);
      expect(s.thresholds.levelFor(30), SeverityLevel.low);
      expect(s.thresholds.levelFor(31), SeverityLevel.medium);
      expect(s.thresholds.levelFor(61), SeverityLevel.high);
      expect(s.thresholds.levelFor(81), SeverityLevel.critical);
    });
  });

  group('Workflow', () {
    late RescueStore store;
    setUp(() => store = RescueStore(startTicker: false)..escalationTimeoutSec = 0);
    tearDown(() => store.dispose());

    test('login rejects bad credentials and accepts demo accounts', () {
      expect(store.login('student01@rescuegrid.demo', 'wrong'), isNotNull);
      expect(store.login('student01@rescuegrid.demo', 'Student@123'), isNull);
      expect(store.currentUser?.role, UserRole.student);
    });

    test('report → auto-assign medical responder → accept → route → arrive → resolve', () {
      store.login('student01@rescuegrid.demo', 'Student@123');
      final inc = store.reportIncident(
        reporter: store.currentUser!,
        category: IncidentCategory.medical,
        description: 'Student feeling unconscious near CSE Department',
        peopleAffected: 2,
        location: store.locationById('cse')!,
      );
      expect(inc.status, IncidentStatus.assigned);
      expect(inc.assignedResponderId, 'R01');

      store.login('responder1@rescuegrid.demo', 'Rescue@123');
      store.accept(inc.id);
      expect(inc.status, IncidentStatus.accepted);
      store.startRoute(inc.id);
      expect(inc.status, IncidentStatus.enRoute);
      store.requestBackup(inc.id, ['Crowd control']);
      expect(inc.backupRequested, isTrue);
      expect(inc.recommendedBackupId, isNotNull);

      for (var i = 0; i < 200 && inc.status == IncidentStatus.enRoute; i++) {
        store.tick();
      }
      expect(inc.status, IncidentStatus.arrived);
      store.markOnScene(inc.id);
      store.resolve(inc.id);
      expect(inc.status, IncidentStatus.resolved);

      final types = store.timeline(inc.id).map((e) => e.type).toList();
      for (final t in [
        TimelineType.reported,
        TimelineType.severity,
        TimelineType.ranking,
        TimelineType.assigned,
        TimelineType.accepted,
        TimelineType.enRoute,
        TimelineType.backupRequested,
        TimelineType.arrived,
        TimelineType.resolved,
        TimelineType.archived,
      ]) {
        expect(types, contains(t));
      }
    });

    test('decline re-assigns to next eligible responder', () {
      store.login('student02@rescuegrid.demo', 'Student@123');
      final inc = store.reportIncident(
        reporter: store.currentUser!,
        category: IncidentCategory.medical,
        description: 'fainted',
        peopleAffected: 1,
        location: store.locationById('cse')!,
      );
      final first = inc.assignedResponderId;
      store.decline(inc.id, 'Busy');
      expect(inc.assignedResponderId, isNot(first));
      expect(inc.declinedBy, contains(first));
      // Every other responder is busy in the seed data, so it waits in the queue.
      expect(inc.isQueued, isTrue);
    });

    test('all busy: queue by severity, redirect from low priority, auto-assign when freed', () {
      store.login('admin@rescuegrid.demo', 'Admin@123');
      final leak = store.reportIncident(
        reporter: store.users['student08']!,
        category: IncidentCategory.flooding,
        description: 'Water leak from the ceiling',
        peopleAffected: 1,
        location: store.locationById('library')!,
      );
      expect(leak.assignedResponderId, 'R01');
      store.accept(leak.id);
      expect(store.freeResponderCount, 0);

      final fight = store.reportIncident(
        reporter: store.users['student06']!,
        category: IncidentCategory.security,
        description: 'Minor fight near the canteen',
        peopleAffected: 2,
        location: store.locationById('canteen')!,
      );
      expect(fight.isQueued, isTrue);

      final crit = store.reportIncident(
        reporter: store.users['student02']!,
        category: IncidentCategory.medical,
        description: 'Student collapsed and not breathing',
        peopleAffected: 3,
        location: store.locationById('auditorium')!,
      );
      expect(crit.severityLevel, SeverityLevel.critical);
      expect(store.queuePosition(crit), 1);
      expect(store.queuePosition(fight), 2);

      expect(store.preemptionFor(crit)?.responder.id, 'R01');
      store.redirectResponder(crit.id);
      expect(crit.assignedResponderId, 'R01');
      expect(leak.isQueued, isTrue);

      store.resolve('INC-1043'); // frees Responder 04
      expect(fight.assignedResponderId ?? leak.assignedResponderId, 'R04');
      expect(store.queue.length, 1);
    });

    test('admin-only actions are enforced', () {
      store.login('student03@rescuegrid.demo', 'Student@123');
      final id = store.activeIncidents.first.id;
      expect(() => store.manualAssign(id, 'R02'), throwsStateError);
      store.login('admin@rescuegrid.demo', 'Admin@123');
      expect(() => store.manualAssign(id, 'R02'), returnsNormally);
    });
  });
}
