/// Solar Hijri (Jalali) date conversion and formatting utility.
class JalaliDate {
  final int year;
  final int month;
  final int day;

  const JalaliDate(this.year, this.month, this.day);

  static const List<String> monthNames = [
    'فروردین',
    'اردیبهشت',
    'خرداد',
    'تیر',
    'مرداد',
    'شهریور',
    'مهر',
    'آبان',
    'آذر',
    'دی',
    'بهمن',
    'اسفند',
  ];

  /// Converts a standard [DateTime] to [JalaliDate].
  factory JalaliDate.fromDateTime(DateTime date) {
    final gYear = date.year;
    final gMonth = date.month;
    final gDay = date.day;

    const gDaysInMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    const jDaysInMonth = [31, 31, 31, 31, 31, 31, 30, 30, 30, 30, 30, 29];

    final gy = gYear - 1600;
    final gm = gMonth - 1;
    final gd = gDay - 1;

    var gDayNo =
        365 * gy + ((gy + 3) ~/ 4) - ((gy + 99) ~/ 100) + ((gy + 399) ~/ 400);

    for (var i = 0; i < gm; ++i) {
      gDayNo += gDaysInMonth[i];
    }
    if (gm > 1 && ((gy % 4 == 0 && gy % 100 != 0) || (gy % 400 == 0))) {
      gDayNo++;
    }
    gDayNo += gd;

    var jDayNo = gDayNo - 79;

    final jNp = jDayNo ~/ 12053;
    jDayNo %= 12053;

    var jy = 979 + 33 * jNp + 4 * (jDayNo ~/ 1461);
    jDayNo %= 1461;

    if (jDayNo >= 366) {
      jy += (jDayNo - 1) ~/ 365;
      jDayNo = (jDayNo - 1) % 365;
    }

    var jm = 0;
    for (var i = 0; i < 11 && jDayNo >= jDaysInMonth[i]; ++i) {
      jDayNo -= jDaysInMonth[i];
      jm = i + 1;
    }
    final jd = jDayNo + 1;

    return JalaliDate(jy, jm + 1, jd);
  }

  /// Format as numeric string `YYYY/MM/DD`.
  String format() {
    return '$year/${month.toString().padLeft(2, '0')}/${day.toString().padLeft(2, '0')}';
  }

  /// Format as readable Persian string, e.g. `۲۸ مهر ۱۴۰۵`.
  String formatReadable({bool persianDigits = true}) {
    final mName = (month >= 1 && month <= 12) ? monthNames[month - 1] : '';
    final text = '$day $mName $year';
    return persianDigits ? toPersianDigits(text) : text;
  }

  /// Converts Latin digits to Persian digits.
  static String toPersianDigits(String input) {
    const latin = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];
    const persian = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];
    var output = input;
    for (var i = 0; i < latin.length; i++) {
      output = output.replaceAll(latin[i], persian[i]);
    }
    return output;
  }
}
