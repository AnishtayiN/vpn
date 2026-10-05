/// Country data used by the exit-IP card: an ISO-3166 alpha-2 code maps to a
/// localized name plus a compact, *paintable* flag design.
///
/// Flags are drawn with a handful of primitives (bands, crosses, discs,
/// cantons, …) instead of shipped images, so the app stays dependency-free,
/// works offline and looks the same on Android and Windows — Windows ships no
/// flag-emoji font, where an emoji flag would degrade to two plain letters.
///
/// Colour conventions, per [FlagKind], are documented on [FlagKind] itself and
/// implemented in `lib/ui/widgets/flag_icon.dart`.
library;

/// How [FlagDesign.colors] is laid out for each kind.
enum FlagKind {
  /// Horizontal bands, top → bottom (weights = band heights).
  hBands,

  /// Vertical bands, left → right (weights = band widths).
  vBands,

  /// `[background, cross, inner cross?]` — off-centre Scandinavian cross.
  nordic,

  /// `[background, cross]` — centred cross.
  cross,

  /// `[background, cross]` — diagonal (saltire) cross.
  crossDiag,

  /// `[background, disc]`.
  disc,

  /// `[background, upper half of disc, lower half of disc]`.
  discSplit,

  /// Thirteen stripes + star field.
  stripesUs,

  /// Union Jack (colours ignored).
  jack,

  /// `[background]` + Union Jack in the canton + stars.
  jackCanton,

  /// `[canton, ...bandsTopToBottom]`.
  canton,

  /// `[...bandsTopToBottom, bar]` — full-height bar on the hoist side.
  barLeft,

  /// `[...bandsTopToBottom, triangle]` — triangle on the hoist side.
  hoistTriangle,

  /// `[upperLeft, band, lowerRight]` — wide band along the descending diagonal.
  diagBand,

  /// `[topLeft, topRight, bottomLeft, bottomRight]` (+ optional centre cross).
  quarters,

  /// `[background, rhombus, disc?]`.
  rhombus,

  /// `[colour]` — flat flag, usually with an emblem.
  solid,
}

enum Emblem {
  none,

  /// Heraldic coat-of-arms silhouette: used where the real emblem is far too
  /// detailed to paint at icon size, so the flag still reads correctly.
  crest,

  /// Small plus sign (used inside a canton).
  cross,
  star,
  starRow,
  crescent,
  crescentStar,
  disc,
  ring,
  sun,
  hexagram,
  chakra,
  leaf,
  iranEmblem,
  script,
}

class FlagDesign {
  const FlagDesign(
    this.kind,
    this.colors, {
    this.weights,
    this.emblem = Emblem.none,
    this.emblemColor = 0xFFFFFF,
    this.stars = 1,
    this.crossColor,
    this.crossDiagonal = false,
  });

  final FlagKind kind;

  /// `0xRRGGBB` values; meaning depends on [kind] (see [FlagKind]).
  final List<int> colors;

  /// Optional relative band sizes — same length as [colors] for band kinds.
  final List<double>? weights;

  final Emblem emblem;
  final int emblemColor;
  final int stars;

  /// Centre cross colour for [FlagKind.quarters].
  final int? crossColor;
  final bool crossDiagonal;
}

class CountryFlag {
  const CountryFlag(this.fa, this.en, this.design);
  final String fa;
  final String en;
  final FlagDesign design;
}

// ─── design helpers ──────────────────────────────────────────────────────────

FlagDesign _h(List<int> c, {List<double>? w, Emblem e = Emblem.none, int ec = 0xFFFFFF, int stars = 1}) =>
    FlagDesign(FlagKind.hBands, c, weights: w, emblem: e, emblemColor: ec, stars: stars);

FlagDesign _v(List<int> c, {List<double>? w, Emblem e = Emblem.none, int ec = 0xFFFFFF}) =>
    FlagDesign(FlagKind.vBands, c, weights: w, emblem: e, emblemColor: ec);

FlagDesign _nordic(int bg, int cross, [int? inner]) =>
    FlagDesign(FlagKind.nordic, [bg, cross, if (inner != null) inner]);

FlagDesign _cross(int bg, int cross) => FlagDesign(FlagKind.cross, [bg, cross]);

FlagDesign _crossDiag(int bg, int cross) => FlagDesign(FlagKind.crossDiag, [bg, cross]);

FlagDesign _disc(int bg, int dot, {Emblem e = Emblem.none, int ec = 0xFFFFFF}) =>
    FlagDesign(FlagKind.disc, [bg, dot], emblem: e, emblemColor: ec);

FlagDesign _solid(int c, {Emblem e = Emblem.none, int ec = 0xFFFFFF, int stars = 1}) =>
    FlagDesign(FlagKind.solid, [c], emblem: e, emblemColor: ec, stars: stars);

FlagDesign _canton(List<int> bands, int canton, {Emblem e = Emblem.none, int ec = 0xFFFFFF}) =>
    FlagDesign(FlagKind.canton, [canton, ...bands], emblem: e, emblemColor: ec);

FlagDesign _barLeft(List<int> bands, int bar, {Emblem e = Emblem.none, int ec = 0xFFFFFF}) =>
    FlagDesign(FlagKind.barLeft, [...bands, bar], emblem: e, emblemColor: ec);

FlagDesign _hoistTri(List<int> bands, int tri, {Emblem e = Emblem.none, int ec = 0xFFFFFF}) =>
    FlagDesign(FlagKind.hoistTriangle, [...bands, tri], emblem: e, emblemColor: ec);

FlagDesign _diag(List<int> colors, {Emblem e = Emblem.none, int ec = 0xFFFFFF}) =>
    FlagDesign(FlagKind.diagBand, colors, emblem: e, emblemColor: ec);

FlagDesign _quarters(List<int> c, {int? cross, bool diagonal = false, Emblem e = Emblem.none, int ec = 0xFFFFFF}) =>
    FlagDesign(FlagKind.quarters, c,
        crossColor: cross, crossDiagonal: diagonal, emblem: e, emblemColor: ec);

FlagDesign _rhombus(int bg, int rhomb, [int? disc]) =>
    FlagDesign(FlagKind.rhombus, [bg, rhomb, if (disc != null) disc]);

FlagDesign _us() => const FlagDesign(FlagKind.stripesUs, [0xB22234, 0xFFFFFF, 0x3C3B6E]);

FlagDesign _jack() => const FlagDesign(FlagKind.jack, [0x012169, 0xFFFFFF, 0xC8102E]);

FlagDesign _jackCanton(int bg, {Emblem e = Emblem.star, int ec = 0xFFFFFF, int stars = 1}) =>
    FlagDesign(FlagKind.jackCanton, [bg], emblem: e, emblemColor: ec, stars: stars);

// ─── table ───────────────────────────────────────────────────────────────────

/// Exit countries the app can realistically see. Anything missing falls back to
/// the plain upper-case code in the UI (never a wrong flag).
final Map<String, CountryFlag> kCountries = {
  // ── Europe ──
  'ad': CountryFlag('آندورا', 'Andorra',
      _v([0x10069F, 0xFEDD00, 0xD0103E], w: [1, 1, 1], e: Emblem.crest, ec: 0xC7B37E)),
  'al': CountryFlag('آلبانی', 'Albania', _solid(0xE41E20, e: Emblem.crest, ec: 0x000000)),
  'am': CountryFlag('ارمنستان', 'Armenia', _h([0xD90012, 0x0033A0, 0xF2A800])),
  'at': CountryFlag('اتریش', 'Austria', _h([0xED2939, 0xFFFFFF, 0xED2939])),
  'az': CountryFlag('آذربایجان', 'Azerbaijan',
      _h([0x00B5E2, 0xEF3340, 0x009C3B], e: Emblem.crescentStar)),
  'ba': CountryFlag('بوسنی و هرزگوین', 'Bosnia and Herzegovina',
      _solid(0x002F6C, e: Emblem.crest, ec: 0xFECB00)),
  'be': CountryFlag('بلژیک', 'Belgium', _v([0x000000, 0xFDDA24, 0xEF3340])),
  'bg': CountryFlag('بلغارستان', 'Bulgaria', _h([0xFFFFFF, 0x00966E, 0xD62612])),
  'by': CountryFlag('بلاروس', 'Belarus', _h([0xC8313E, 0x00966E], w: [2, 1])),
  'ch': CountryFlag('سوئیس', 'Switzerland', _cross(0xD52B1E, 0xFFFFFF)),
  'cy': CountryFlag('قبرس', 'Cyprus', _solid(0xFFFFFF, e: Emblem.crest, ec: 0xD57800)),
  'cz': CountryFlag('چک', 'Czechia', _hoistTri([0xFFFFFF, 0xD7141A], 0x11457E)),
  'de': CountryFlag('آلمان', 'Germany', _h([0x000000, 0xDD0000, 0xFFCE00])),
  'dk': CountryFlag('دانمارک', 'Denmark', _nordic(0xC8102E, 0xFFFFFF)),
  'ee': CountryFlag('استونی', 'Estonia', _h([0x0072CE, 0x000000, 0xFFFFFF])),
  'es': CountryFlag('اسپانیا', 'Spain',
      _h([0xAA151B, 0xF1BF00, 0xAA151B], w: [1, 2, 1], e: Emblem.crest, ec: 0xAA151B)),
  'fi': CountryFlag('فنلاند', 'Finland', _nordic(0xFFFFFF, 0x002F6C)),
  'fo': CountryFlag('جزایر فارو', 'Faroe Islands', _nordic(0xFFFFFF, 0xED2939, 0x002F6C)),
  'fr': CountryFlag('فرانسه', 'France', _v([0x002395, 0xFFFFFF, 0xED2939])),
  'gb': CountryFlag('بریتانیا', 'United Kingdom', _jack()),
  'ge': CountryFlag('گرجستان', 'Georgia', _cross(0xFFFFFF, 0xE1001A)),
  'gg': CountryFlag('گرنزی', 'Guernsey', _cross(0xFFFFFF, 0xCE1124)),
  'gi': CountryFlag('جبل‌طارق', 'Gibraltar', _h([0xFFFFFF, 0xDA1C1C], w: [2, 1])),
  'gr': CountryFlag('یونان', 'Greece',
      _canton([0x0D5EAF, 0xFFFFFF, 0x0D5EAF, 0xFFFFFF, 0x0D5EAF], 0x0D5EAF, e: Emblem.cross)),
  'hr': CountryFlag('کرواسی', 'Croatia',
      _h([0xFF0000, 0xFFFFFF, 0x171796], e: Emblem.crest, ec: 0xC8102E)),
  'hu': CountryFlag('مجارستان', 'Hungary', _h([0xCE2939, 0xFFFFFF, 0x477050])),
  'ie': CountryFlag('ایرلند', 'Ireland', _v([0x169B62, 0xFFFFFF, 0xFF883E])),
  'im': CountryFlag('جزیره من', 'Isle of Man', _solid(0xCF142B, e: Emblem.crest, ec: 0xF9DD16)),
  'is': CountryFlag('ایسلند', 'Iceland', _nordic(0x02529C, 0xFFFFFF, 0xDC1E35)),
  'it': CountryFlag('ایتالیا', 'Italy', _v([0x008C45, 0xF4F5F0, 0xCD212A])),
  'je': CountryFlag('جرزی', 'Jersey', _crossDiag(0xFFFFFF, 0xCE1124)),
  'li': CountryFlag('لیختن‌اشتاین', 'Liechtenstein',
      _h([0x002B7F, 0xCE1126], e: Emblem.crest, ec: 0xF9DD16)),
  'lt': CountryFlag('لیتوانی', 'Lithuania', _h([0xFDB913, 0x006A44, 0xC1272D])),
  'lu': CountryFlag('لوکزامبورگ', 'Luxembourg', _h([0xED2939, 0xFFFFFF, 0x00A1DE])),
  'lv': CountryFlag('لتونی', 'Latvia', _h([0x9E3039, 0xFFFFFF, 0x9E3039], w: [2, 1, 2])),
  'mc': CountryFlag('موناکو', 'Monaco', _h([0xCE1126, 0xFFFFFF])),
  'md': CountryFlag('مولداوی', 'Moldova',
      _v([0x003DA5, 0xFFD200, 0xC8102E], e: Emblem.crest, ec: 0xC8102E)),
  'me': CountryFlag('مونته‌نگرو', 'Montenegro', _solid(0xC8102E, e: Emblem.crest, ec: 0xFECB00)),
  'mk': CountryFlag('مقدونیه شمالی', 'North Macedonia',
      _solid(0xD20000, e: Emblem.sun, ec: 0xFFE600)),
  'mt': CountryFlag('مالت', 'Malta', _v([0xFFFFFF, 0xCF142B], e: Emblem.crest, ec: 0x9E9E9E)),
  'nl': CountryFlag('هلند', 'Netherlands', _h([0xAE1C28, 0xFFFFFF, 0x21468B])),
  'no': CountryFlag('نروژ', 'Norway', _nordic(0xBA0C2F, 0xFFFFFF, 0x00205B)),
  'pl': CountryFlag('لهستان', 'Poland', _h([0xFFFFFF, 0xDC143C])),
  'pt': CountryFlag('پرتغال', 'Portugal',
      _v([0x046A38, 0xFF0000], w: [2, 3], e: Emblem.crest, ec: 0xFFE900)),
  'ro': CountryFlag('رومانی', 'Romania', _v([0x002B7F, 0xFCD116, 0xCE1126])),
  'rs': CountryFlag('صربستان', 'Serbia',
      _h([0xC6363C, 0x0C4076, 0xFFFFFF], e: Emblem.crest, ec: 0xEDB92E)),
  'ru': CountryFlag('روسیه', 'Russia', _h([0xFFFFFF, 0x0039A6, 0xD52B1E])),
  'se': CountryFlag('سوئد', 'Sweden', _nordic(0x006AA7, 0xFECC00)),
  'si': CountryFlag('اسلوونی', 'Slovenia',
      _h([0xFFFFFF, 0x005DA4, 0xED1C24], e: Emblem.crest, ec: 0xED1C24)),
  'sk': CountryFlag('اسلواکی', 'Slovakia',
      _h([0xFFFFFF, 0x0B4EA2, 0xEE1C25], e: Emblem.crest, ec: 0xEE1C25)),
  'sm': CountryFlag('سان‌مارینو', 'San Marino',
      _h([0xFFFFFF, 0x5EB6E4], e: Emblem.crest, ec: 0x5EB6E4)),
  'tr': CountryFlag('ترکیه', 'Türkiye', _solid(0xE30A17, e: Emblem.crescentStar)),
  'ua': CountryFlag('اوکراین', 'Ukraine', _h([0x0057B7, 0xFFDD00])),
  'va': CountryFlag('واتیکان', 'Vatican City',
      _v([0xFFE100, 0xFFFFFF], e: Emblem.crest, ec: 0xC2B280)),
  'xk': CountryFlag('کوزوو', 'Kosovo', _solid(0x244AA5, e: Emblem.crest, ec: 0xD0A650)),

  // ── Middle East & Central Asia ──
  'ae': CountryFlag('امارات', 'United Arab Emirates',
      _barLeft([0x00732F, 0xFFFFFF, 0x000000], 0xCE1126)),
  'af': CountryFlag('افغانستان', 'Afghanistan',
      _v([0x000000, 0xD32011, 0x007A36], e: Emblem.crest, ec: 0xFFFFFF)),
  'bh': CountryFlag('بحرین', 'Bahrain', _barLeft([0xCE1126], 0xFFFFFF)),
  'il': CountryFlag('اسرائیل', 'Israel',
      _h([0x0038B8, 0xFFFFFF, 0x0038B8], w: [1, 4, 1], e: Emblem.hexagram, ec: 0x0038B8)),
  'iq': CountryFlag('عراق', 'Iraq',
      _h([0xCE1126, 0xFFFFFF, 0x000000], e: Emblem.script, ec: 0x007A3D)),
  'ir': CountryFlag('ایران', 'Iran',
      _h([0x239F40, 0xFFFFFF, 0xDA0000], e: Emblem.iranEmblem, ec: 0xDA0000)),
  'jo': CountryFlag('اردن', 'Jordan',
      _hoistTri([0x000000, 0xFFFFFF], 0xCE1126, e: Emblem.star, ec: 0xFFFFFF)),
  'kg': CountryFlag('قرقیزستان', 'Kyrgyzstan', _solid(0xE8112D, e: Emblem.sun, ec: 0xFFEF00)),
  'kw': CountryFlag('کویت', 'Kuwait',
      _hoistTri([0x007A3D, 0xFFFFFF, 0xCE1126], 0x000000)),
  'kz': CountryFlag('قزاقستان', 'Kazakhstan', _solid(0x00AFCA, e: Emblem.sun, ec: 0xFEC50C)),
  'lb': CountryFlag('لبنان', 'Lebanon',
      _h([0xCE1126, 0xFFFFFF, 0xCE1126], e: Emblem.leaf, ec: 0x00A651)),
  'om': CountryFlag('عمان', 'Oman',
      _barLeft([0xFFFFFF, 0xCE1126, 0x007A3D], 0xCE1126, e: Emblem.crest, ec: 0xFFFFFF)),
  'ps': CountryFlag('فلسطین', 'Palestine',
      _hoistTri([0x000000, 0xFFFFFF, 0x007A3D], 0xCE1126)),
  'qa': CountryFlag('قطر', 'Qatar', _barLeft([0x8A1538], 0xFFFFFF)),
  'sa': CountryFlag('عربستان', 'Saudi Arabia', _solid(0x165D31, e: Emblem.script)),
  'sy': CountryFlag('سوریه', 'Syria',
      _h([0xCE1126, 0xFFFFFF, 0x000000], e: Emblem.starRow, ec: 0x007A3D, stars: 2)),
  'tj': CountryFlag('تاجیکستان', 'Tajikistan',
      _h([0xCC0000, 0xFFFFFF, 0x006600], e: Emblem.crest, ec: 0xF8C300)),
  'tm': CountryFlag('ترکمنستان', 'Turkmenistan',
      _solid(0x00843D, e: Emblem.crescentStar)),
  'uz': CountryFlag('ازبکستان', 'Uzbekistan',
      _h([0x0099B5, 0xFFFFFF, 0x1EB53A], e: Emblem.crescentStar)),
  'ye': CountryFlag('یمن', 'Yemen', _h([0xCE1126, 0xFFFFFF, 0x000000])),

  // ── South & East Asia, Oceania ──
  'au': CountryFlag('استرالیا', 'Australia', _jackCanton(0x00008B, stars: 6)),
  'bd': CountryFlag('بنگلادش', 'Bangladesh', _disc(0x006A4E, 0xF42A41)),
  'bn': CountryFlag('برونئی', 'Brunei',
      _diag([0xF7E017, 0xFFFFFF, 0x000000], e: Emblem.crest, ec: 0xCE1126)),
  'bt': CountryFlag('بوتان', 'Bhutan', _diag([0xFF4E12, 0xFFFFFF, 0xFFD520])),
  'cn': CountryFlag('چین', 'China',
      _solid(0xDE2910, e: Emblem.starRow, ec: 0xFFDE00, stars: 5)),
  'fj': CountryFlag('فیجی', 'Fiji', _jackCanton(0x68BFE5)),
  'hk': CountryFlag('هنگ‌کنگ', 'Hong Kong', _solid(0xDE2910, e: Emblem.leaf)),
  'id': CountryFlag('اندونزی', 'Indonesia', _h([0xFF0000, 0xFFFFFF])),
  'in': CountryFlag('هند', 'India',
      _h([0xFF9933, 0xFFFFFF, 0x138808], e: Emblem.chakra, ec: 0x000080)),
  'jp': CountryFlag('ژاپن', 'Japan', _disc(0xFFFFFF, 0xBC002D)),
  'kh': CountryFlag('کامبوج', 'Cambodia',
      _h([0x032EA1, 0xE00025, 0x032EA1], w: [1, 2, 1], e: Emblem.crest, ec: 0xFFFFFF)),
  'kp': CountryFlag('کره شمالی', 'North Korea',
      _h([0x024FA2, 0xFFFFFF, 0xED1C27], w: [2, 3, 2], e: Emblem.disc)),
  'kr': const CountryFlag('کره جنوبی', 'South Korea',
      FlagDesign(FlagKind.discSplit, [0xFFFFFF, 0xCD2E3A, 0x0047A0])),
  'la': CountryFlag('لائوس', 'Laos',
      _h([0xCE1126, 0x002868, 0xCE1126], w: [1, 2, 1], e: Emblem.disc)),
  'lk': CountryFlag('سری‌لانکا', 'Sri Lanka',
      _v([0x00534E, 0xEB7400, 0x8D2029], w: [1, 1, 3], e: Emblem.crest, ec: 0xFFB700)),
  'mm': CountryFlag('میانمار', 'Myanmar',
      _h([0xFECB00, 0x34B233, 0xEA2839], e: Emblem.star)),
  'mn': CountryFlag('مغولستان', 'Mongolia',
      _v([0xCE1126, 0x0033A0, 0xCE1126], e: Emblem.crest, ec: 0xF9CF16)),
  'mo': CountryFlag('ماکائو', 'Macao', _solid(0x00785E, e: Emblem.leaf)),
  'mv': CountryFlag('مالدیو', 'Maldives', _solid(0xD21034, e: Emblem.crescentStar)),
  'my': CountryFlag('مالزی', 'Malaysia',
      _canton([0xCC0001, 0xFFFFFF, 0xCC0001, 0xFFFFFF, 0xCC0001, 0xFFFFFF, 0xCC0001],
          0x010066, e: Emblem.crescentStar, ec: 0xFFCC00)),
  'np': CountryFlag('نپال', 'Nepal', _solid(0xDC143C, e: Emblem.sun, ec: 0xFFFFFF)),
  'nz': CountryFlag('نیوزیلند', 'New Zealand', _jackCanton(0x00247D, stars: 4)),
  'pg': CountryFlag('پاپوآ گینه نو', 'Papua New Guinea',
      _diag([0xCE1126, 0x000000, 0x000000], e: Emblem.star)),
  'ph': CountryFlag('فیلیپین', 'Philippines',
      _hoistTri([0x0038A8, 0xCE1126], 0xFFFFFF, e: Emblem.star, ec: 0xFCD116)),
  'pk': CountryFlag('پاکستان', 'Pakistan',
      _barLeft([0x01411C], 0xFFFFFF, e: Emblem.crescentStar, ec: 0xFFFFFF)),
  'sg': CountryFlag('سنگاپور', 'Singapore',
      _h([0xED2939, 0xFFFFFF], e: Emblem.crescentStar)),
  'th': CountryFlag('تایلند', 'Thailand',
      _h([0xA51931, 0xF4F5F8, 0x2D2A4A, 0xF4F5F8, 0xA51931], w: [1, 1, 2, 1, 1])),
  'tl': CountryFlag('تیمور شرقی', 'Timor-Leste',
      _hoistTri([0xFFC726, 0x000000], 0xCE1126, e: Emblem.star, ec: 0xFFFFFF)),
  'tw': CountryFlag('تایوان', 'Taiwan',
      _canton([0xFE0000], 0x000095, e: Emblem.sun, ec: 0xFFFFFF)),
  'vn': CountryFlag('ویتنام', 'Vietnam', _solid(0xDA251D, e: Emblem.star, ec: 0xFFFF00)),
  'vu': CountryFlag('وانواتو', 'Vanuatu',
      _hoistTri([0xCE1126, 0x009543], 0x000000, e: Emblem.ring, ec: 0xFDCE12)),
  'ws': CountryFlag('ساموآ', 'Samoa', _canton([0xCE1126], 0x000066, e: Emblem.star)),

  // ── Africa ──
  'ao': CountryFlag('آنگولا', 'Angola',
      _h([0xCE1126, 0x000000], e: Emblem.crest, ec: 0xF9D616)),
  'bf': CountryFlag('بورکینافاسو', 'Burkina Faso',
      _h([0xEF2B2D, 0x009E49], e: Emblem.star, ec: 0xFCD116)),
  'bi': CountryFlag('بوروندی', 'Burundi',
      _h([0xCE1126, 0xFFFFFF, 0x1EB53A], e: Emblem.starRow, ec: 0xCE1126, stars: 3)),
  'bj': CountryFlag('بنین', 'Benin', _barLeft([0xFCD116, 0xE8112D], 0x008751)),
  'bw': CountryFlag('بوتسوانا', 'Botswana',
      _h([0x75AADB, 0xFFFFFF, 0x000000, 0xFFFFFF, 0x75AADB], w: [4, 1, 2, 1, 4])),
  'cd': CountryFlag('کنگو (دموکراتیک)', 'DR Congo',
      _diag([0x007FFF, 0xF7D618, 0xCE1021], e: Emblem.star, ec: 0xF7D618)),
  'cg': CountryFlag('کنگو', 'Congo', _diag([0x009543, 0xFBDE4A, 0xDC241F])),
  'ci': CountryFlag('ساحل عاج', 'Côte d’Ivoire', _v([0xF77F00, 0xFFFFFF, 0x009E60])),
  'cm': CountryFlag('کامرون', 'Cameroon',
      _v([0x007A5E, 0xCE1126, 0xFCD116], e: Emblem.star, ec: 0xFCD116)),
  'cv': CountryFlag('کیپ‌ورد', 'Cabo Verde',
      _h([0x003893, 0xFFFFFF, 0xCF2027, 0xFFFFFF, 0x003893],
          w: [4, 1, 1, 1, 1], e: Emblem.ring, ec: 0xF7D116)),
  'dj': CountryFlag('جیبوتی', 'Djibouti',
      _hoistTri([0x6AB2E7, 0x12AD2B], 0xFFFFFF, e: Emblem.star, ec: 0xD7141A)),
  'dz': CountryFlag('الجزایر', 'Algeria',
      _v([0x006233, 0xFFFFFF], e: Emblem.crescentStar, ec: 0xD21034)),
  'eg': CountryFlag('مصر', 'Egypt',
      _h([0xCE1126, 0xFFFFFF, 0x000000], e: Emblem.crest, ec: 0xC09300)),
  'er': CountryFlag('اریتره', 'Eritrea',
      _hoistTri([0x12AD2B, 0x4189DD], 0xEA0437, e: Emblem.ring, ec: 0xFFC726)),
  'et': CountryFlag('اتیوپی', 'Ethiopia',
      _h([0x078930, 0xFCDD09, 0xDA121A], e: Emblem.ring, ec: 0x0F47AF)),
  'ga': CountryFlag('گابن', 'Gabon', _h([0x009E60, 0xFCD116, 0x3A75C4])),
  'gh': CountryFlag('غنا', 'Ghana',
      _h([0xCE1126, 0xFCD116, 0x006B3F], e: Emblem.star, ec: 0x000000)),
  'gm': CountryFlag('گامبیا', 'Gambia',
      _h([0xCE1126, 0xFFFFFF, 0x0C1C8C, 0xFFFFFF, 0x3A7728], w: [3, 1, 3, 1, 3])),
  'gn': CountryFlag('گینه', 'Guinea', _v([0xCE1126, 0xFCD116, 0x009460])),
  'ke': CountryFlag('کنیا', 'Kenya',
      _h([0x000000, 0xFFFFFF, 0xBB0000, 0xFFFFFF, 0x006600], w: [3, 1, 3, 1, 3],
          e: Emblem.crest, ec: 0xBB0000)),
  'lr': CountryFlag('لیبریا', 'Liberia',
      _canton([0xBF0A30, 0xFFFFFF, 0xBF0A30, 0xFFFFFF, 0xBF0A30], 0x002868,
          e: Emblem.star)),
  'ly': CountryFlag('لیبی', 'Libya',
      _h([0xE70013, 0x000000, 0x239E46], e: Emblem.crescentStar)),
  'ma': CountryFlag('مراکش', 'Morocco', _solid(0xC1272D, e: Emblem.star, ec: 0x006233)),
  'mg': CountryFlag('ماداگاسکار', 'Madagascar', _barLeft([0xFC3D32, 0x007E3A], 0xFFFFFF)),
  'ml': CountryFlag('مالی', 'Mali', _v([0x14B53A, 0xFCD116, 0xCE1126])),
  'mu': CountryFlag('موریس', 'Mauritius', _h([0xEA2839, 0x1A206D, 0xFFD500, 0x00A551])),
  'mz': CountryFlag('موزامبیک', 'Mozambique',
      _hoistTri([0x009739, 0x000000, 0xFCE100], 0xCE1126, e: Emblem.star, ec: 0xFFFFFF)),
  'na': CountryFlag('نامیبیا', 'Namibia',
      _diag([0x003580, 0xFFFFFF, 0x009543], e: Emblem.sun, ec: 0xFCD116)),
  'ne': CountryFlag('نیجر', 'Niger',
      _h([0xE05206, 0xFFFFFF, 0x0DB02B], e: Emblem.disc, ec: 0xE05206)),
  'ng': CountryFlag('نیجریه', 'Nigeria', _v([0x008751, 0xFFFFFF, 0x008751])),
  'rw': CountryFlag('رواندا', 'Rwanda',
      _h([0x00A1DE, 0xFAD201, 0x20603D], w: [2, 1, 1], e: Emblem.sun, ec: 0xE5BE01)),
  'sc': CountryFlag('سیشل', 'Seychelles', _v([0x003F87, 0xFCD856, 0xD62828])),
  'sd': CountryFlag('سودان', 'Sudan',
      _hoistTri([0xCE1126, 0xFFFFFF, 0x000000], 0x007229)),
  'sl': CountryFlag('سیرالئون', 'Sierra Leone', _h([0x1EB53A, 0xFFFFFF, 0x0072C6])),
  'sn': CountryFlag('سنگال', 'Senegal',
      _v([0x00853F, 0xFDEF42, 0xE31B23], e: Emblem.star, ec: 0x00853F)),
  'so': CountryFlag('سومالی', 'Somalia', _solid(0x4189DD, e: Emblem.star)),
  'ss': CountryFlag('سودان جنوبی', 'South Sudan',
      _hoistTri([0x000000, 0xDA121A, 0x078930], 0x0F47AF, e: Emblem.star, ec: 0xFCDD09)),
  'td': CountryFlag('چاد', 'Chad', _v([0x002664, 0xFECB00, 0xC60C30])),
  'tg': CountryFlag('توگو', 'Togo',
      _canton([0x006A4E, 0xFFCE00, 0x006A4E, 0xFFCE00, 0x006A4E], 0xD21034,
          e: Emblem.star)),
  'tn': CountryFlag('تونس', 'Tunisia',
      _disc(0xE70013, 0xFFFFFF, e: Emblem.crescentStar, ec: 0xE70013)),
  'tz': CountryFlag('تانزانیا', 'Tanzania', _diag([0x1EB53A, 0x000000, 0x00A3DD])),
  'ug': CountryFlag('اوگاندا', 'Uganda',
      _h([0x000000, 0xFCDC04, 0xD90000, 0x000000, 0xFCDC04, 0xD90000], e: Emblem.disc)),
  'za': CountryFlag('آفریقای جنوبی', 'South Africa',
      _hoistTri([0xDE3831, 0xFFFFFF, 0x007A4D, 0xFFFFFF, 0x002395], 0x000000)),
  'zm': CountryFlag('زامبیا', 'Zambia', _solid(0x198A00, e: Emblem.crest, ec: 0xEF7D00)),
  'zw': CountryFlag('زیمبابوه', 'Zimbabwe',
      _hoistTri([0x009739, 0xFFD200, 0xEF3340, 0x000000, 0xEF3340, 0xFFD200, 0x009739],
          0xFFFFFF, e: Emblem.star, ec: 0xEF3340)),

  // ── Americas ──
  'ar': CountryFlag('آرژانتین', 'Argentina',
      _h([0x74ACDF, 0xFFFFFF, 0x74ACDF], e: Emblem.sun, ec: 0xF6B40E)),
  'bb': CountryFlag('باربادوس', 'Barbados',
      _v([0x00267F, 0xFFC726, 0x00267F], e: Emblem.crest, ec: 0x000000)),
  'bo': CountryFlag('بولیوی', 'Bolivia',
      _h([0xD52B1E, 0xF9E300, 0x007934], e: Emblem.crest, ec: 0x8D6E3A)),
  'br': CountryFlag('برزیل', 'Brazil', _rhombus(0x009C3B, 0xFFDF00, 0x002776)),
  'bs': CountryFlag('باهاما', 'Bahamas', _hoistTri([0x00778B, 0xFFC72C, 0x00778B], 0x000000)),
  'bz': CountryFlag('بلیز', 'Belize',
      _h([0xCE1126, 0x003F87, 0x003F87, 0xCE1126], w: [1, 3, 3, 1], e: Emblem.disc)),
  'ca': CountryFlag('کانادا', 'Canada',
      _v([0xD80621, 0xFFFFFF, 0xD80621], w: [1, 2, 1], e: Emblem.leaf, ec: 0xD80621)),
  'cl': CountryFlag('شیلی', 'Chile',
      _canton([0xFFFFFF, 0xD52B1E], 0x0039A6, e: Emblem.star)),
  'co': CountryFlag('کلمبیا', 'Colombia',
      _h([0xFCD116, 0x003893, 0xCE1126], w: [2, 1, 1])),
  'cr': CountryFlag('کاستاریکا', 'Costa Rica',
      _h([0x002B7F, 0xFFFFFF, 0xCE1126, 0xFFFFFF, 0x002B7F], w: [1, 1, 2, 1, 1])),
  'cu': CountryFlag('کوبا', 'Cuba',
      _hoistTri([0x002A8F, 0xFFFFFF, 0x002A8F, 0xFFFFFF, 0x002A8F], 0xCF142B,
          e: Emblem.star)),
  'do': CountryFlag('جمهوری دومینیکن', 'Dominican Republic',
      _quarters([0x002D62, 0xCE1126, 0xCE1126, 0x002D62], cross: 0xFFFFFF)),
  'ec': CountryFlag('اکوادور', 'Ecuador',
      _h([0xFFDD00, 0x034EA2, 0xED1C24], w: [2, 1, 1], e: Emblem.crest, ec: 0x8D6E3A)),
  'gt': CountryFlag('گواتمالا', 'Guatemala',
      _v([0x4997D0, 0xFFFFFF, 0x4997D0], e: Emblem.crest, ec: 0x006847)),
  'gy': CountryFlag('گویان', 'Guyana',
      _hoistTri([0x009E49], 0xFCD116, e: Emblem.crest, ec: 0x000000)),
  'hn': CountryFlag('هندوراس', 'Honduras',
      _h([0x0073CF, 0xFFFFFF, 0x0073CF], e: Emblem.starRow, ec: 0x0073CF, stars: 5)),
  'ht': CountryFlag('هائیتی', 'Haiti',
      _canton([0x00209F, 0xD21034], 0xFFFFFF, e: Emblem.crest, ec: 0x007A3D)),
  'jm': CountryFlag('جامائیکا', 'Jamaica',
      _quarters([0x009B3A, 0x000000, 0x000000, 0x009B3A], cross: 0xFED100, diagonal: true)),
  'mx': CountryFlag('مکزیک', 'Mexico',
      _v([0x006847, 0xFFFFFF, 0xCE1126], e: Emblem.crest, ec: 0x8D6E3A)),
  'ni': CountryFlag('نیکاراگوئه', 'Nicaragua',
      _h([0x0067C6, 0xFFFFFF, 0x0067C6], e: Emblem.crest, ec: 0x0067C6)),
  'pa': CountryFlag('پاناما', 'Panama',
      _quarters([0xFFFFFF, 0xD21034, 0x005293, 0xFFFFFF], e: Emblem.star, ec: 0x005293)),
  'pe': CountryFlag('پرو', 'Peru', _v([0xD91023, 0xFFFFFF, 0xD91023])),
  'pr': CountryFlag('پورتوریکو', 'Puerto Rico',
      _hoistTri([0xED0000, 0xFFFFFF, 0xED0000, 0xFFFFFF, 0xED0000], 0x0050F0,
          e: Emblem.star)),
  'py': CountryFlag('پاراگوئه', 'Paraguay',
      _h([0xD52B1E, 0xFFFFFF, 0x0038A8], e: Emblem.crest, ec: 0x009739)),
  'sr': CountryFlag('سورینام', 'Suriname',
      _h([0x377E3F, 0xFFFFFF, 0xB40A2E, 0xFFFFFF, 0x377E3F], w: [2, 1, 4, 1, 2],
          e: Emblem.star, ec: 0xECC81D)),
  'sv': CountryFlag('السالوادور', 'El Salvador',
      _h([0x0F47AF, 0xFFFFFF, 0x0F47AF], e: Emblem.crest, ec: 0x0F47AF)),
  'tt': CountryFlag('ترینیداد و توباگو', 'Trinidad and Tobago',
      _diag([0xCE1126, 0xFFFFFF, 0x000000])),
  'us': CountryFlag('ایالات متحده', 'United States', _us()),
  'uy': CountryFlag('اروگوئه', 'Uruguay',
      _canton([0xFFFFFF, 0x0038A8, 0xFFFFFF, 0x0038A8, 0xFFFFFF], 0xFFFFFF,
          e: Emblem.sun, ec: 0xFCD116)),
  've': CountryFlag('ونزوئلا', 'Venezuela',
      _h([0xFFCC00, 0x00247D, 0xCF142B], e: Emblem.starRow, stars: 8)),
};

/// Lookup by ISO-3166 alpha-2 code, any case. Returns null for unknown or
/// anonymised codes (Tor's `T1`, Cloudflare's `XX`, …) so the UI can fall back
/// to the bare code instead of showing a wrong flag.
CountryFlag? countryFlag(String? code) {
  final c = code?.trim().toLowerCase() ?? '';
  if (c.length != 2) return null;
  return kCountries[c];
}

/// Localized country name, or the upper-case code when there is no entry.
String countryLabel(String? code, {required bool fa}) {
  final c = code?.trim() ?? '';
  if (c.isEmpty) return '';
  final hit = countryFlag(c);
  if (hit == null) return c.toUpperCase();
  return fa ? hit.fa : hit.en;
}
