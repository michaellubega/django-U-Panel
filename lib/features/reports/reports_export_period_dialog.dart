import 'package:flutter/material.dart';

import '../campus_presence/campus_presence_grouping.dart';

/// Day / week / month + anchor date for roll PDF exports.
class ReportsExportPeriodChoice {
  const ReportsExportPeriodChoice({
    required this.period,
    required this.anchor,
  });

  final CampusPresenceLogPeriod period;
  final DateTime anchor;

  String describeRange() {
    final range = localDateRangeForPeriod(period, anchor);
    String fmt(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    if (period == CampusPresenceLogPeriod.day) return fmt(range.start);
    return '${fmt(range.start)} – ${fmt(range.end)}';
  }
}

Future<ReportsExportPeriodChoice?> showReportsExportPeriodDialog(
  BuildContext context, {
  CampusPresenceLogPeriod initialPeriod = CampusPresenceLogPeriod.week,
  DateTime? initialAnchor,
}) {
  return showDialog<ReportsExportPeriodChoice>(
    context: context,
    builder: (ctx) => _ReportsExportPeriodDialog(
      initialPeriod: initialPeriod,
      initialAnchor: initialAnchor ?? DateTime.now(),
    ),
  );
}

class _ReportsExportPeriodDialog extends StatefulWidget {
  const _ReportsExportPeriodDialog({
    required this.initialPeriod,
    required this.initialAnchor,
  });

  final CampusPresenceLogPeriod initialPeriod;
  final DateTime initialAnchor;

  @override
  State<_ReportsExportPeriodDialog> createState() =>
      _ReportsExportPeriodDialogState();
}

class _ReportsExportPeriodDialogState extends State<_ReportsExportPeriodDialog> {
  late CampusPresenceLogPeriod _period = widget.initialPeriod;
  late DateTime _anchor = widget.initialAnchor;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _anchor,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() => _anchor = picked);
  }

  @override
  Widget build(BuildContext context) {
    final choice = ReportsExportPeriodChoice(period: _period, anchor: _anchor);
    return AlertDialog(
      title: const Text('Export period'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<CampusPresenceLogPeriod>(
              segments: [
                for (final p in CampusPresenceLogPeriod.values)
                  ButtonSegment(value: p, label: Text(p.label)),
              ],
              selected: {_period},
              onSelectionChanged: (s) => setState(() => _period = s.first),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today_rounded, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        choice.describeRange(),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                    const Icon(Icons.edit_calendar_rounded, size: 18),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, choice),
          icon: const Icon(Icons.picture_as_pdf_rounded, size: 18),
          label: const Text('Generate PDF'),
        ),
      ],
    );
  }
}
