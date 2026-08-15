import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../attendance/data/attendance_repository.dart';
import 'create_notice_screen.dart';
import 'data/notices_repository.dart';

/// Opens [CreateNoticeScreen] and publishes the draft when the user confirms.
/// Returns `true` when the notice was saved successfully.
Future<bool> openCreateNoticeAndPublish(BuildContext context) async {
  await AttendanceRepository.instance.loadAttendanceListsFirst(force: false);

  if (!context.mounted) return;
  final draft = await Navigator.of(context).push<NoticeCreationResult>(
    MaterialPageRoute(
      builder: (ctx) => const CreateNoticeScreen(),
    ),
  );
  if (!context.mounted || draft == null) return;

  var author = AuthRepository.instance.currentFullName?.trim() ?? '';
  if (author.isEmpty) {
    author = AuthRepository.instance.currentEmail?.trim() ?? '';
  }
  if (author.isEmpty) {
    final auth = AuthRepository.instance;
    if (auth.lecturerCheckDone && auth.isLecturer && !auth.isAdmin) {
      author = 'Lecturer';
    } else if (auth.isKiuAdmin) {
      author = 'KIU Admin';
    } else {
      author = 'Admin';
    }
  }

  final err = await NoticesRepository.instance.publish(
    draft: draft,
    author: author,
  );
  if (!context.mounted) return;
  if (err != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not save notice: $err'),
        duration: const Duration(seconds: 6),
      ),
    );
    return false;
  }

  final audienceBit = switch (draft.audience) {
    NoticeAudienceKind.allAppUsers => 'All app users',
    NoticeAudienceKind.kiuAdmins => 'KIU administrators',
    NoticeAudienceKind.classList =>
      'Class list: ${draft.targetListTitle ?? 'list'}',
    NoticeAudienceKind.student => 'Individual student',
  };
  final msg = draft.scheduledFor == null
      ? (draft.sendPush
          ? 'Notice sent ($audienceBit). People subscribed to notices will get an alert.'
          : 'Notice published ($audienceBit).')
      : (draft.sendPush
          ? 'Notice scheduled ($audienceBit). An alert will go out at the scheduled time.'
          : 'Notice scheduled ($audienceBit).');
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg)),
  );
  return true;
}
