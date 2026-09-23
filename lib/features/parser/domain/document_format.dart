/// Detected document format. PRD §2 Module 2.
enum DocumentFormat {
  txt,
  markdown,
  docx,
  doc, // legacy binary; P2 / degrade path
  pdf,
  image, // OCR route
  rtf,
  html,
  unknown,
}

extension DocumentFormatX on DocumentFormat {
  bool get isOcrRequired => this == DocumentFormat.image;
  String get label => switch (this) {
        DocumentFormat.txt => 'txt',
        DocumentFormat.markdown => 'md',
        DocumentFormat.docx => 'docx',
        DocumentFormat.doc => 'doc',
        DocumentFormat.pdf => 'pdf',
        DocumentFormat.image => 'img',
        DocumentFormat.rtf => 'rtf',
        DocumentFormat.html => 'html',
        DocumentFormat.unknown => '?',
      };
}
