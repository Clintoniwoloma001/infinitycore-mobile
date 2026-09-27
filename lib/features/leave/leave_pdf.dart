import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

import 'leave_service.dart';

/// Approved-leave certificate generator.
///
/// Deliberately dependency-free: a small, correct PDF 1.4 writer producing a
/// printable record with the full approval trail (including any dates an
/// approver revised) and every sign-off. Sharing goes through the
/// already-shipped `share_plus` plugin, so "print as PDF" reaches the
/// platform print dialog without adding a rendering plugin.
class LeavePdf {
  LeavePdf._();

  static const double _pageWidth = 595;
  static const double _pageHeight = 842;
  static const double _margin = 48;
  static const double _lineHeight = 15;
  static const double _bodySize = 10;
  static const double _titleSize = 16;

  /// Builds the PDF bytes for [request] plus its [trail].
  static Uint8List build({
    required LeaveRequest request,
    required List<LeaveApproval> trail,
    required List<Map<String, String>> chain,
    String employeeName = '',
  }) {
    final pages = _layout(request, trail, chain, employeeName);
    return _write(pages);
  }

  /// Builds and shares the record. Returns false when sharing is unavailable.
  static Future<bool> share({
    required LeaveRequest request,
    required List<LeaveApproval> trail,
    required List<Map<String, String>> chain,
    String employeeName = '',
  }) async {
    final bytes = build(
      request: request,
      trail: trail,
      chain: chain,
      employeeName: employeeName,
    );
    try {
      final dir = await Directory.systemTemp.createTemp('leave_pdf');
      final file = File(
        '${dir.path}/leave-${request.id.isEmpty ? 'request' : request.id}.pdf',
      );
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/pdf')],
          subject: 'Approved leave — ${request.label}',
          text: 'Approved leave record for ${request.employeeName}',
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------------
  // Layout — plain text lines with a simple style marker.
  // ------------------------------------------------------------------

  static List<_Line> _lines(
    LeaveRequest request,
    List<LeaveApproval> trail,
    List<Map<String, String>> chain,
    String employeeName,
  ) {
    final out = <_Line>[];
    void title(String t) => out.add(_Line(t, bold: true, size: _titleSize));
    void head(String t) => out.add(_Line(t, bold: true, size: 11));
    void body(String t) => out.add(_Line(t, size: _bodySize));
    void gap() => out.add(const _Line(''));

    title('InfinityCore');
    body('Infinity Microfinance Bank — Leave Approval Record');
    gap();
    head('Employee');
    body(employeeName.isEmpty ? request.employeeName : employeeName);
    gap();
    head('Request');
    body('Leave type: ${request.label}');
    body('Period: ${request.startDate} to ${request.endDate}');
    body(
      'Working days: '
      '${request.days.toStringAsFixed(request.days % 1 == 0 ? 0 : 1)}',
    );
    body('Status: ${request.status.toUpperCase()}');
    body('Raised: ${request.createdAt}');
    if (request.reason.trim().isNotEmpty) {
      body('Reason: ${request.reason}');
    }
    gap();
    head('Approval chain');
    final effectiveChain = chain.isEmpty ? defaultApprovalChain : chain;
    for (var i = 0; i < effectiveChain.length; i++) {
      body('${i + 1}. ${effectiveChain[i]['label'] ?? ''}');
    }
    gap();
    head('Approval trail');
    if (trail.isEmpty) {
      body('No decisions recorded yet.');
    } else {
      for (final a in trail) {
        body(
          '${a.stageLabel.isEmpty ? a.stageKey : a.stageLabel}'
          ' — ${a.decision.toUpperCase()}'
          '${a.approverName.isEmpty ? '' : ' by ${a.approverName}'}',
        );
        if (a.createdAt.isNotEmpty) body('  Signed: ${a.createdAt}');
        if (a.hasRevisedDates) {
          body(
            '  Dates revised by approver: '
            '${a.revisedStart.isEmpty ? request.startDate : a.revisedStart}'
            ' to '
            '${a.revisedEnd.isEmpty ? request.endDate : a.revisedEnd}',
          );
        }
        if (a.comment.trim().isNotEmpty) body('  Comment: ${a.comment}');
        if (a.signature.trim().isNotEmpty) body('  Sign-off: ${a.signature}');
        gap();
      }
    }
    gap();
    body(
      'Generated ${DateTime.now().toIso8601String().split('.').first} · '
      'InfinityCore Mobile',
    );
    return out;
  }

  static List<List<_Line>> _layout(
    LeaveRequest request,
    List<LeaveApproval> trail,
    List<Map<String, String>> chain,
    String employeeName,
  ) {
    final all = _lines(request, trail, chain, employeeName);
    final perPage = ((_pageHeight - _margin * 2) / _lineHeight).floor();
    final pages = <List<_Line>>[];
    for (var i = 0; i < all.length; i += perPage) {
      pages.add(
        all.sublist(i, (i + perPage > all.length) ? all.length : i + perPage),
      );
    }
    return pages.isEmpty ? [<_Line>[]] : pages;
  }

  // ------------------------------------------------------------------
  // PDF serialisation
  // ------------------------------------------------------------------

  static Uint8List _write(List<List<_Line>> pages) {
    final n = pages.length;
    // 1 catalog · 2 page tree · 3..n+2 pages · n+3..2n+2 content · fonts last.
    final fontRegular = 2 * n + 3;
    final fontBold = 2 * n + 4;
    final total = 2 * n + 4;

    final kids = [
      for (var i = 0; i < n; i++) '${3 + i} 0 R',
    ].join(' ');

    final bodies = <int, String>{
      1: '<< /Type /Catalog /Pages 2 0 R >>',
      2:
          '<< /Type /Pages /Kids [$kids] /Count $n >>',
      fontRegular:
          '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
          '/Encoding /WinAnsiEncoding >>',
      fontBold:
          '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold '
          '/Encoding /WinAnsiEncoding >>',
    };

    for (var i = 0; i < n; i++) {
      final contentId = n + 3 + i;
      bodies[3 + i] =
          '<< /Type /Page /Parent 2 0 R '
          '/MediaBox [0 0 ${_pageWidth.toStringAsFixed(0)} '
          '${_pageHeight.toStringAsFixed(0)}] '
          '/Resources << /Font << /F1 $fontRegular 0 R /F2 $fontBold 0 R >> >> '
          '/Contents $contentId 0 R >>';
      final stream = _content(pages[i]);
      bodies[contentId] =
          '<< /Length ${stream.length} >>\nstream\n$stream\nendstream';
    }

    final buffer = BytesBuilder();
    void put(String s) => buffer.add(latin1.encode(s));

    put('%PDF-1.4\n');
    final offsets = <int, int>{};
    for (var id = 1; id <= total; id++) {
      offsets[id] = buffer.length;
      put('$id 0 obj\n${bodies[id]}\nendobj\n');
    }
    final xrefAt = buffer.length;
    put('xref\n0 ${total + 1}\n');
    put('0000000000 65535 f \n');
    for (var id = 1; id <= total; id++) {
      put('${offsets[id]!.toString().padLeft(10, '0')} 00000 n \n');
    }
    put(
      'trailer\n<< /Size ${total + 1} /Root 1 0 R >>\n'
      'startxref\n$xrefAt\n%%EOF\n',
    );
    return buffer.toBytes();
  }

  /// Draws one page. Each line is positioned explicitly so mixed font sizes
  /// need no leading state.
  static String _content(List<_Line> lines) {
    final sb = StringBuffer('BT\n');
    var y = _pageHeight - _margin;
    for (final line in lines) {
      if (line.text.trim().isNotEmpty) {
        sb
          ..writeln(
            '1 0 0 1 ${_margin.toStringAsFixed(1)} ${y.toStringAsFixed(1)} Tm',
          )
          ..writeln('/${line.bold ? 'F2' : 'F1'} ${line.size} Tf')
          ..writeln('(${_escape(line.text)}) Tj');
      }
      y -= _lineHeight;
    }
    sb.write('ET');
    return sb.toString();
  }

  /// PDF string escaping; non-ASCII is transliterated because the built-in
  /// WinAnsi font cannot represent arbitrary Unicode.
  static String _escape(String value) {
    final ascii = _toAscii(value);
    return ascii
        .replaceAll('\\', r'\\')
        .replaceAll('(', r'\(')
        .replaceAll(')', r'\)');
  }

  static String _toAscii(String value) {
    const map = {
      '–': '-',
      '—': '-',
      '’': "'",
      '‘': "'",
      '“': '"',
      '”': '"',
      '·': '-',
      '∞': 'infinite',
      '→': '->',
    };
    final sb = StringBuffer();
    for (final rune in value.runes) {
      final ch = String.fromCharCode(rune);
      final mapped = map[ch];
      if (mapped != null) {
        sb.write(mapped);
      } else if (rune >= 32 && rune <= 126) {
        sb.write(ch);
      } else if (rune == 10 || rune == 13) {
        sb.write(' ');
      } else {
        sb.write('?');
      }
    }
    return sb.toString();
  }
}

class _Line {
  const _Line(this.text, {this.bold = false, this.size = 10});

  final String text;
  final bool bold;
  final double size;
}
