import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/firebase/firestore_collections.dart';
import '../../core/firebase/u_panel_firestore.dart';
import '../../core/theme/app_theme.dart';

/// Admin-only directory of full administrators ([admins], not QA staff).
class AdministratorsListScreen extends StatelessWidget {
  const AdministratorsListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Administrators'),
        backgroundColor: AppTheme.secondary,
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
              .where((d) => AuthRepository.adminDocIsFullAdministrator(d.data()))
              .toList()
            ..sort((a, b) {
              final sa = (a.data()['staffNumber'] as String?) ??
                  (a.data()['registrationNumber'] as String?) ??
                  '';
              final sb = (b.data()['staffNumber'] as String?) ??
                  (b.data()['registrationNumber'] as String?) ??
                  '';
              return sa.compareTo(sb);
            });
          if (docs.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No administrators yet. Use Grant administrator access '
                  'from Staff & accounts.',
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
              final data = docs[i].data();
              final staff = (data['staffNumber'] as String?) ??
                  (data['registrationNumber'] as String?) ??
                  '—';
              final name = (data['fullName'] as String?)?.trim();
              final title =
                  (name != null && name.isNotEmpty) ? name : staff;
              final subtitle =
                  (name != null && name.isNotEmpty && staff != '—')
                      ? staff
                      : null;
              return ListTile(
                title: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: subtitle != null
                    ? Text(subtitle, style: const TextStyle(fontSize: 12))
                    : null,
              );
            },
          );
        },
      ),
    );
  }
}
