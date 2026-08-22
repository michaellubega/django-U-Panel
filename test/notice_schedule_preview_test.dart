import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/features/notices/create_notice_screen.dart';
import 'package:u_panel/features/notices/data/notices_repository.dart';

NoticeRecord _manualNotice({
  required NoticeAudienceKind audience,
  String? targetListId,
}) {
  return NoticeRecord(
    id: 'n1',
    title: 'Test',
    body: 'Body',
    author: 'Admin',
    createdAt: DateTime.utc(2026, 3, 1, 8),
    scheduledFor: DateTime.utc(2099, 1, 1, 12),
    sendPush: true,
    audience: audience,
    targetListId: targetListId,
    kind: 'manual',
  );
}

void main() {
  test('admin can preview scheduled class-list notices', () {
    final notice = _manualNotice(
      audience: NoticeAudienceKind.classList,
      targetListId: 'list-1',
    );
    expect(
      noticeAllowsPendingPreview(n: notice, admin: true),
      isTrue,
    );
    expect(noticeIsLive(notice), isFalse);
    expect(
      noticeVisibleToUser(
        notice,
        admin: true,
        studentId: null,
        signedListIds: const {},
      ),
      isTrue,
    );
  });

  test('kiu admin can preview scheduled class-list notices', () {
    final notice = _manualNotice(
      audience: NoticeAudienceKind.classList,
      targetListId: 'list-1',
    );
    expect(
      noticeAllowsPendingPreview(
        n: notice,
        admin: false,
        kiuAdmin: true,
      ),
      isTrue,
    );
  });
}
