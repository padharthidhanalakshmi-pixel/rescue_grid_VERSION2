import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../data/safety_guidance.dart';
import '../../models/enums.dart';
import '../../models/incident.dart';
import '../../services/incident_service.dart';
import '../../widgets/common.dart';
import '../incidents/incident_detail_screen.dart';
import 'assign_sheet.dart';

/// Red banner + priority queue shown on the Command Center when every
/// responder is busy.
class QueuePanel extends StatelessWidget {
  const QueuePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<RescueStore>();
    final q = store.queue;
    if (q.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: RgColors.red.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: RgColors.red),
        ),
        child: Row(children: [
          const PulseDot(),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                store.freeResponderCount == 0 ? '⚠ NO RESPONDERS FREE' : '⚠ INCIDENTS WAITING',
                style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2, color: RgColors.red),
              ),
              Text('${q.length} incident(s) queued · ordered by severity · auto-assign when a responder is free',
                  style: const TextStyle(fontSize: 12.5)),
            ]),
          ),
        ]),
      ),
      const SectionTitle('Priority queue'),
      for (var i = 0; i < q.length; i++) QueueCard(inc: q[i], position: i + 1),
    ]);
  }
}

class QueueCard extends StatelessWidget {
  const QueueCard({super.key, required this.inc, required this.position});
  final Incident inc;
  final int position;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<RescueStore>();
    final p = store.preemptionFor(inc);
    final wait = inc.queueWait?.inSeconds ?? 0;
    final overdue = inc.waitWarningRaised;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Panel(
        border: inc.severityLevel.color,
        onTap: () => IncidentDetailScreen.open(context, inc.id),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: inc.severityLevel.color, borderRadius: BorderRadius.circular(10)),
              child: Text('#$position',
                  style: AppTheme.mono.copyWith(fontWeight: FontWeight.w900, color: Colors.black, fontSize: 15)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${inc.category.emoji} ${inc.id} · ${inc.category.label}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(inc.locationName, style: const TextStyle(color: RgColors.muted, fontSize: 12.5)),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              const Text('WAITING', style: TextStyle(fontSize: 9.5, color: RgColors.muted, letterSpacing: 1.2)),
              Text(Fmt.mmss(wait),
                  style: AppTheme.mono.copyWith(
                      fontWeight: FontWeight.w900, fontSize: 18, color: overdue ? RgColors.red : RgColors.text)),
            ]),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            SeverityBadge(inc.severityLevel, inc.severityScore, dense: true),
            if (overdue) const Pill('WAIT LIMIT EXCEEDED', color: RgColors.red, dense: true),
            for (final e in inc.externalHelp) Pill('📞 $e', color: RgColors.amber, dense: true),
            if (inc.offDutyAlerted) const Pill('OFF-DUTY ALERTED', color: RgColors.blue, dense: true),
          ]),
          if (p != null) ...[
            const SizedBox(height: 8),
            Text('↪ ${p.responder.name} can be redirected from lower-priority ${p.from.id} '
                '(${p.from.severityLevel.label} ${p.from.severityScore})',
                style: const TextStyle(color: RgColors.amber, fontSize: 12.5, fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 8),
          QueueActions(inc: inc),
        ]),
      ),
    );
  }
}

/// Admin actions for a queued incident.
class QueueActions extends StatelessWidget {
  const QueueActions({super.key, required this.inc});
  final Incident inc;

  @override
  Widget build(BuildContext context) {
    final store = context.read<RescueStore>();
    final p = store.preemptionFor(inc);
    return Wrap(spacing: 8, runSpacing: 8, children: [
      if (p != null)
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: RgColors.orange, foregroundColor: Colors.black),
          icon: const Icon(Icons.swap_horiz, size: 18),
          label: Text('REDIRECT ${p.responder.name.toUpperCase()}'),
          onPressed: () => guarded(context, () => store.redirectResponder(inc.id),
              success: '${p.responder.name} redirected to ${inc.id}. ${p.from.id} re-queued.'),
        ),
      OutlinedButton.icon(
        icon: const Icon(Icons.local_hospital, size: 18),
        label: const Text('EXTERNAL HELP'),
        onPressed: () => showExternalHelpSheet(context, inc.id),
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.campaign_outlined, size: 18),
        label: const Text('ALERT OFF-DUTY'),
        onPressed: () {
          try {
            final n = store.alertOffDuty(inc.id);
            showMsg(context, n == 0 ? 'No off-duty responders to alert.' : 'Alert sent to $n off-duty responder(s).');
          } on StateError catch (e) {
            showMsg(context, e.message, color: RgColors.redDeep);
          }
        },
      ),
      TextButton(onPressed: () => showAssignSheet(context, inc.id), child: const Text('ASSIGN MANUALLY')),
    ]);
  }
}

Future<void> showExternalHelpSheet(BuildContext context, String incidentId) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: RgColors.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      final store = ctx.read<RescueStore>();
      return SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
          const Text('CONTACT EXTERNAL HELP', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2)),
          const SizedBox(height: 4),
          const Text('Opens the phone dialer and logs the request on the incident timeline.',
              style: TextStyle(color: RgColors.muted, fontSize: 12)),
          const SizedBox(height: 10),
          for (final ExternalContact c in store.externalContacts)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.call, color: RgColors.red),
              title: Text(c.name),
              subtitle: Text(c.number.isEmpty ? 'Number not configured (Settings)' : c.number),
              onTap: () async {
                final label = c.number.isEmpty ? c.name : '${c.name} (${c.number})';
                guarded(ctx, () => store.logExternalHelp(incidentId, label));
                Navigator.pop(ctx);
                if (c.number.isNotEmpty) {
                  try {
                    await launchUrl(Uri(scheme: 'tel', path: c.number));
                  } catch (_) {
                    // Dialer unavailable (emulator / tablet); request is still logged.
                  }
                }
              },
            ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: () {
              guarded(ctx, () => store.logExternalHelp(incidentId, 'External help (logged without call)'));
              Navigator.pop(ctx);
            },
            child: const Text('LOG ONLY — DEMO, NO CALL'),
          ),
        ]),
      );
    },
  );
}

/// Safety steps shown to the reporting student while waiting.
class SafetyGuidanceCard extends StatelessWidget {
  const SafetyGuidanceCard({super.key, required this.category});
  final IncidentCategory category;

  @override
  Widget build(BuildContext context) {
    return Panel(
      border: RgColors.amber,
      color: RgColors.amber.withValues(alpha: 0.08),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('WHILE YOU WAIT — STAY SAFE',
            style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2, color: RgColors.amber)),
        const SizedBox(height: 8),
        for (final g in safetyGuidance(category))
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('•  ', style: TextStyle(color: RgColors.amber, fontWeight: FontWeight.w900)),
              Expanded(child: Text(g, style: const TextStyle(height: 1.3))),
            ]),
          ),
      ]),
    );
  }
}
