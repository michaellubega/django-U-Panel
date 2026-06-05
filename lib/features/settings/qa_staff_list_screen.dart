import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/firebase/firestore_collections.dart';
import '../../core/firebase/u_panel_firestore.dart';
import '../../core/theme/app_theme.dart';

/// Admin-only directory of QA staff ([admins] with `isAdmin: true`).
class QaStaffListScreen extends StatelessWidget {
  const QaStaffListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('QA staff (admins)'),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: uPanelFirestore()
            .collection(FirestoreCollections.admins)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data!.docs
              .where((d) => d.data()['isAdmin'] == true)
              .toList()
            ..sort((a, b) {
              final ra = (a.data()['registrationNumber'] as String?) ?? '';
              final rb = (b.data()['registrationNumber'] as String?) ?? '';
              return ra.compareTo(rb);
            });
          if (docs.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No admin accounts found.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final d = docs[i];
              final data = d.data();
              final reg = (data['registrationNumber'] as String?) ?? '—';
              final name = (data['fullName'] as String?)?.trim();
              final title = (name != null && name.isNotEmpty)
                  ? name
                  : (reg != '—' ? reg : 'Staff account');
              final sub = (name != null && name.isNotEmpty)
                  ? (reg != '—'
                      ? '$reg\nUID: ${d.id}'
                      : 'UID: ${d.id}')
                  : (reg != '—'
                      ? 'UID: ${d.id}'
                      : 'UID: ${d.id}');
              return ListTile(
                title: Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle:
                    Text(sub, style: const TextStyle(fontSize: 12)),
                isThreeLine: true,
              );
            },
          );
        },
      ),
    );
  }
}
