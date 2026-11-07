'use strict';
/* نموذج تصميم: يتفاعل ولا يحفظ شيئاً، والتحميل والتصدير محاكاة. */
const A = {};
for (const [k, v] of Object.entries(window.ASSETS)) {
  const [head, b64] = v.split(',');
  const bin = atob(b64), u = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
  A[k] = URL.createObjectURL(new Blob([u], { type: head.slice(5, head.indexOf(';')) }));
}
document.documentElement.style.setProperty('--tile-script', `url(${A['tile-script']})`);
document.documentElement.style.setProperty('--stone', `url(${A.stone})`);

const DATA = window.DATA, BK = DATA.books;
const n = x => String(x).replace(/\d/g, d => '٠١٢٣٤٥٦٧٨٩'[d]);
const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const P = {
  back: '<path d="M5 12h14M13 6l6 6-6 6"/>', chev: '<path d="m15 6-6 6 6 6"/>', close: '<path d="m6 6 12 12M18 6 6 18"/>', check: '<path d="m5 12.500 4.500 4.500L19 7.500"/>',
  more: '<circle cx="5.500" cy="12" r="1.300"/><circle cx="12" cy="12" r="1.300"/><circle cx="18.500" cy="12" r="1.300"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  laser: '<circle cx="6" cy="18" r="2.300"/><path d="m8 16 8-8M14.500 4.500l1 2M19.500 9.500l-2-1M20 4l-2 1.500"/>', image: '<rect x="3.500" y="5" width="17" height="14" rx="2"/><circle cx="9" cy="10" r="1.700"/><path d="m4 17 5-4 3.500 3 3-2.500L20 17"/>',
  toc: '<path d="M4 6h1M4 12h1M4 18h1M9 6h11M9 12h11M9 18h11"/>', open: '<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
  recent: '<circle cx="12" cy="12" r="8.500"/><path d="M12 7v5.300l3.500 2"/>', inked: '<path d="M6 3h9l4 4v13a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z"/><path d="m8 16 1-3 6-6 2 2-6 6z"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4.500 20.500c1.200-3.800 4-5.500 7.500-5.500s6.300 1.700 7.500 5.500"/>',
  menu: '<path d="M4 7h16M4 12h16M4 17h10"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.600 5.600l2.100 2.100M16.300 16.300l2.100 2.100M18.400 5.600l-2.100 2.100M7.700 16.300l-2.100 2.100"/>',
  fav: '<path d="m12 3.600 2.600 5.500 6 .8-4.400 4.200 1.100 6-5.300-2.900-5.300 2.900 1.100-6L3.400 9.900l6-.8z"/>',
  search: '<circle cx="11" cy="11" r="6.500"/><path d="m16 16 4.500 4.500"/>',
  hand: '<path d="M8 12V6a1.500 1.500 0 0 1 3 0v5-7a1.500 1.500 0 0 1 3 0v7-5a1.500 1.500 0 0 1 3 0v8c0 4-2.400 7-6 7-2.600 0-4-1.200-5.200-3L3.500 13.500c-.8-1.300 1-2.600 2.200-1.500L8 14.200"/>',
  pen: '<path d="M4 20l1-4.500L16.500 4a2.100 2.100 0 0 1 3 0l.5.5a2.100 2.100 0 0 1 0 3L8.500 19z"/><path d="m14.500 6 3.500 3.500"/>',
  hl: '<path d="m8 15 8.500-10.500 4 3.300L12 18.300z"/><path d="m8 15-.8 3.500 3 1.500 1.800-1.700M4 21h7"/>',
  eraser: '<path d="M9 20 3.700 14.700a1.500 1.500 0 0 1 0-2.100l8.900-8.900a1.500 1.500 0 0 1 2.100 0l5.600 5.600a1.500 1.500 0 0 1 0 2.100L12 20zM8 8.500l7.500 7.500M9 20h11"/>',
  lasso: '<path d="M6.500 16.500C4.300 15.200 3 13.400 3 11.500 3 7.400 7 4 12 4s9 3.400 9 7.500-4 7.500-9 7.500c-.9 0-1.700-.1-2.500-.3" stroke-dasharray="3 2.600"/><circle cx="7.500" cy="18" r="1.800"/>',
  shape: '<rect x="3.500" y="10" width="10.500" height="10.500" rx="1.500"/><circle cx="15.500" cy="8.500" r="5"/>',
  text: '<path d="M5 6V4.500h14V6M12 4.500V20M9 20h6"/>',
  pin: '<path d="M12 21s-6.500-5.400-6.500-11a6.500 6.500 0 0 1 13 0c0 5.600-6.500 11-6.500 11z"/><circle cx="12" cy="10" r="2.300"/>',
  tape: '<rect x="3" y="8.500" width="18" height="7" rx="1.500"/><path d="M7 8.500v7M17 8.500v7" stroke-dasharray="1.500 1.500"/>',
  word: '<path d="M4 19h16"/><path d="m7 15 4-10h2l4 10M8.500 11.500h7"/>',
  ruler: '<path d="m3.500 16.500 13-13 4 4-13 13z"/><path d="m7 13 2 2m1-5 2.500 2.500M13 7l2 2"/>',
  undo: '<path d="M15 8H7l3.500-3.500M7 8l3.500 3.500M7.500 19H14a5 5 0 0 0 0-10"/>',
  redo: '<path d="M9 8h8l-3.500-3.500M17 8l-3.500 3.500M16.500 19H10a5 5 0 0 1 0-10"/>',
  grid: '<rect x="4" y="4" width="7" height="7" rx="1.500"/><rect x="13" y="4" width="7" height="7" rx="1.500"/><rect x="4" y="13" width="7" height="7" rx="1.500"/><rect x="13" y="13" width="7" height="7" rx="1.500"/>',
  bm: '<path d="M7 3h10a1 1 0 0 1 1 1v17l-6-4-6 4V4a1 1 0 0 1 1-1z"/>',
  share: '<path d="M12 15V4M8 7.500 12 3.500l4 4M6 12H5a1 1 0 0 0-1 1v7a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-7a1 1 0 0 0-1-1h-1"/>',
  lib: '<path d="M5 4h4v16H5zM10.500 4h4v16h-4z"/><path d="m16.200 5.200 3.700 1-3.600 13.600-3.700-1"/>',
  store: '<path d="M4 9.500 5.500 4h13L20 9.500M4 9.500a2.700 2.700 0 0 0 5.300 0 2.700 2.700 0 0 0 5.400 0 2.700 2.700 0 0 0 5.300 0M5 12v8h14v-8M10 20v-5h4v5"/>',
  note: '<path d="M6 3h9l4 4v13a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z"/><path d="M15 3v4h4M8.500 12h7M8.500 16h5"/>',
  file: '<path d="M6 3h8l5 5v12a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z"/><path d="M14 3v5h5"/>',
  cloud: '<path d="M7 18.500a4.500 4.500 0 0 1-.6-9 6 6 0 0 1 11.500 1.300 3.900 3.900 0 0 1-.6 7.700z"/>',
  dl: '<path d="M12 4v11M7.500 11 12 15.500 16.500 11M5 20h14"/>',
  sort: '<path d="M4 7h16M7 12h10M10 17h4"/>', filter: '<path d="M4 5h16l-6 7.500V19l-4 1.500v-8z"/>',
  photo: '<rect x="3.500" y="5" width="17" height="14" rx="2"/><circle cx="9" cy="10" r="1.700"/><path d="m4 17 5-4 3.500 3 3-2.500L20 17"/>',
  pdf: '<path d="M6 3h8l5 5v12a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z"/><path d="M14 3v5h5M8.500 16.500h7M8.500 13h4"/>',
  box: '<path d="m3.500 7.500 8.500-4 8.500 4v9l-8.500 4-8.500-4z"/><path d="m3.500 7.500 8.500 4 8.500-4M12 11.500v9"/>',
  save: '<path d="M12 4v11M7.500 11 12 15.500 16.500 11M5 20h14"/>',
  expand: '<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/>', sun: '<circle cx="12" cy="12" r="4"/><path d="M12 3v2M12 19v2M3 12h2M19 12h2M5.600 5.600 7 7M17 17l1.400 1.400M18.400 5.600 17 7M7 17l-1.400 1.400"/>',
  warn: '<path d="M12 4 2.500 20h19zM12 10v5M12 17.500v.1"/>', out: '<path d="M10 4H6a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h4M14 8l-4 4 4 4M10 12h10"/>',
  edit: '<path d="M4 20h4l11-11-4-4L4 16z"/>', trash: '<path d="M5 7h14M9 7V4h6v3M7 7l1 13h8l1-13"/>', swap: '<path d="M4 8h13l-3.500-3.500M20 16H7l3.500 3.500"/>', touch: '<path d="M9 11V5.500a1.500 1.500 0 0 1 3 0V11l5 1.500c1 .3 1.500 1.200 1.300 2.200L17.500 20h-7L6 14.500c-.8-1 .4-2.300 1.500-1.600L9 14"/>',
};
const ic = k => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${P[k]}</svg>`;
const STAR = '<svg viewBox="0 0 100 100" aria-hidden="true"><path fill="currentColor" d="M50 2 64 16h20v20l14 14-14 14v20H64L50 98 36 84H16V64L2 50l14-14V16h20z"/></svg>';
const logo = s => `<div class="logo" style="--s:${s}px"><span>نوتس</span></div>`;
const RIGHTS = 'جميع الحقوق محفوظة © ٢٠٢٦ مؤسسة الحكمة للثقافة الإسلامية';
const cov = (id, extra = '') => `<div class="cov"><img src="${A['c' + id]}" alt="" loading="lazy">${extra}</div>`;

/* القوالب: ورقة A4 بعرض 210 */
function tplBody(id) {
  const l = '#D6CFBE', t = '#16233A', G = '#B8923E';
  const L = (a, b, c, d, w = .5, col = l) => `<line x1="${a}" y1="${b}" x2="${c}" y2="${d}" stroke="${col}" stroke-width="${w}"/>`;
  const T = (x, y, s, z = 7, an = 'start', w = 700, col = t) => `<text x="${x}" y="${y}" font-size="${z}" font-weight="${w}" text-anchor="${an}" fill="${col}" font-family="Muna,sans-serif">${s}</text>`;
  const R = (x, y, w, h, r = 3) => `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${r}" fill="none" stroke="${l}" stroke-width=".6"/>`;
  const rules = (x1, x2, y1, y2, st = 9) => { let o = ''; for (let y = y1; y <= y2; y += st) o += L(x1, y, x2, y); return o; };
  const head = s => T(196, 21, s, 10, 'start', 900) + L(14, 26, 196, 26, .9, G);
  switch (id) {
    case 'lined': return rules(14, 196, 24, 285);
    case 'grid': { let o = ''; for (let x = 7; x <= 210; x += 7) o += L(x, 0, x, 297, .3); for (let y = 7; y <= 297; y += 7) o += L(0, y, 210, y, .3); return o; }
    case 'cornell': return head('تلخيص الدرس') + L(142, 26, 142, 232, .7) + T(196, 37, 'العناوين', 7, 'start', 700, G) + T(136, 37, 'الملاحظات', 7, 'start', 700, G) + rules(14, 136, 46, 228) + L(14, 232, 196, 232, .9, G) + T(196, 243, 'الخلاصة', 7, 'start', 700, G) + rules(14, 196, 252, 285);
    case 'taqrir': return head('تقرير الدرس') + [['المادة', 196], ['الأستاذ', 134], ['التاريخ', 72]].map(([s, x]) => T(x, 38, s, 6.500) + L(x - 56, 42, x, 42)).join('') + ['موضوع الدرس', 'خلاصة التقرير', 'الإشكال والجواب'].map((s, i) => { const y = 56 + i * 78; return T(196, y, s, 8, 'start', 900, G) + rules(14, 196, y + 11, y + 66); }).join('');
    case 'mubahatha': return head('المباحثة') + L(105, 30, 105, 224, .7) + T(196, 39, 'طرحي', 7.500, 'start', 900, G) + T(98, 39, 'طرح الزميل', 7.500, 'start', 900, G) + rules(112, 196, 48, 220) + rules(14, 98, 48, 220) + L(14, 228, 196, 228, .9, G) + T(196, 240, 'النتيجة', 7.500, 'start', 900, G) + rules(14, 196, 250, 285);
    case 'masala': return head('بطاقة مسألة') + T(196, 38, 'رقم المسألة', 6.500) + R(120, 42, 76, 14) + T(112, 38, 'المصدر', 6.500) + R(14, 42, 98, 14) + [['نص المسألة', 62, 82], ['الحكم', 156, 46], ['ملاحظات', 214, 66]].map(([s, y, h]) => T(196, y + 6, s, 7, 'start', 900, G) + R(14, y + 10, 182, h - 10)).join('');
    case 'compare': return head('مقارنة فتاوى') + R(14, 32, 182, 252, 4) + L(136, 32, 136, 284) + L(75, 32, 75, 284) + L(14, 46, 196, 46, .9, G) + T(166, 42, 'المسألة', 7, 'middle', 900) + T(105, 42, 'السيد السيستاني', 6.500, 'middle', 900) + T(44, 42, 'السيد الحكيم', 6.500, 'middle', 900) + rules(14, 196, 86, 270, 40);
    case 'tree': { const bx = (x, y, w = 52) => R(x - w / 2, y, w, 18, 4); const cn = (a, b, c, d) => `<path d="M${a} ${b} V${(b + d) / 2} H${c} V${d}" fill="none" stroke="${l}" stroke-width=".7"/>`; return head('شجرة الأقسام') + bx(105, 40, 70) + cn(105, 58, 57, 88) + cn(105, 58, 153, 88) + bx(57, 88) + bx(153, 88) + cn(153, 106, 121, 136) + cn(153, 106, 185, 136) + cn(57, 106, 25, 136) + cn(57, 106, 89, 136) + [25, 89, 121, 185].map(x => bx(x, 136, 30)).join('') + rules(14, 196, 186, 285); }
  }
  return '';
}
function inkBody(k) {
  const H = (x, y, s, z = 9, c = '#1C4F92', an = 'middle') => `<text x="${x}" y="${y}" font-size="${z}" fill="${c}" text-anchor="${an}" font-family="'Aref Ruqaa',serif">${s}</text>`;
  if (k === 'tree') return H(105, 53, 'الماء', 11) + H(57, 101, 'مطلق', 10) + H(153, 101, 'مضاف', 10, '#C8372D') + H(25, 149, 'قليل', 8) + H(89, 149, 'كرّ', 8) + H(121, 149, 'طبيعية', 7) + H(185, 149, 'كالحمام', 7) + H(190, 200, 'ما لا مادة له: قليل أو كثير يبلغ الكر', 9.500, '#1A1A1A', 'start') + H(190, 218, 'وما له مادة: طبيعية، أو كماء الحمام', 9.500, '#1A1A1A', 'start');
  if (k === 'cornell') return H(192, 58, 'مادة الأمر', 9, '#1C4F92', 'start') + H(192, 112, 'صيغة الأمر', 9, '#1C4F92', 'start') + H(132, 58, 'الجهة الأولى: معناها', 8.500, '#1A1A1A', 'start') + H(132, 76, 'الجهة الثانية: الطلب والإرادة', 8.500, '#1A1A1A', 'start') + H(132, 112, 'دلالتها على الوجوب', 8.500, '#1A1A1A', 'start') + H(192, 263, 'أعد قراءة الباب قبل المباحثة', 9, '#1E8A5A', 'start');
  if (k === 'masala') return H(190, 53, '٤٥', 10, '#1C4F92', 'start') + H(106, 53, 'منهاج الصالحين ١ : ٤١', 9, '#1C4F92', 'start') + H(190, 90, 'يعتبر في جريان حكم ماء المطر', 9.500, '#1A1A1A', 'start') + H(190, 106, 'أن يصدق عرفاً أن النازل من السماء (ماء مطر)', 9.500, '#1A1A1A', 'start') + H(190, 232, 'قارنها بالمسألة ٤٦ و٤٧', 9, '#1E8A5A', 'start');
  return '';
}
const paperSVG = (id, ink) => `<svg viewBox="0 0 210 297" xmlns="http://www.w3.org/2000/svg">${tplBody(id)}${ink ? inkBody(ink) : ''}</svg>`;

const NOTES = [
  { id: 'n1', t: 'أقسام الماء', tpl: 'tree', ink: 'tree', d: 'اليوم' }, { id: 'n2', t: 'الأوامر: تلخيص الدرس', tpl: 'cornell', ink: 'cornell', d: 'أمس' },
  { id: 'n3', t: 'ماء المطر', tpl: 'masala', ink: 'masala', d: 'الخميس' }, { id: 'n4', t: 'شرائط التقليد', tpl: 'compare', d: 'الثلاثاء' },
];
const TPLS = [['', 'بيضاء'], ['lined', 'مسطّرة'], ['grid', 'مربعات'], ['cornell', 'تلخيص الدرس'], ['taqrir', 'تقرير الدرس'], ['mubahatha', 'المباحثة'], ['masala', 'بطاقة مسألة'], ['compare', 'مقارنة فتاوى'], ['tree', 'شجرة الأقسام']];
const COL = { pen: ['#16233A', '#1C4F92', '#C8372D', '#1E8A5A', '#B8923E'], hl: ['#FFE27A', '#A8E6BE', '#A9D3F7', '#F7B6C2'], laser: ['#E5262A', '#17A34A', '#1F7AE0'] };
const ALLT = { hand: 'تحريك', pen: 'قلم', hl: 'تظليل', eraser: 'ممحاة', lasso: 'تحديد', laser: 'ليزر', shape: 'أشكال', text: 'نص', pin: 'ملاحظة', tape: 'شريط', word: 'الكلمات', ruler: 'المسطرة', image: 'صورة' };
const BAR0 = ['hand', 'pen', 'hl', 'eraser', 'lasso'], BOX0 = ['laser', 'shape', 'text', 'pin', 'tape', 'word', 'ruler', 'image'];
const KINDS = { pen: [['ink', 'حبر'], ['pencil', 'رصاص'], ['cal', 'خط عربي']], eraser: [['part', 'ممحاة عادية'], ['whole', 'خط كامل']], shape: [['line', 'خط'], ['arrow', 'سهم'], ['rect', 'مستطيل'], ['ellipse', 'دائرة'], ['tri', 'مثلث']], word: [['hl', 'تظليل'], ['under', 'تسطير'], ['strike', 'شطب'], ['color', 'لون الخط'], ['comment', 'تعليق']] };
const TOC = [[1, 'كتاب الطهارة'], [2, 'المبحث الأول: أقسام المياه وأحكامها'], [3, 'الفصل الأول: ينقسم ما يستعمل فيه لفظ الماء إلى قسمين', 1], [3, 'الفصل الثاني: الماء المطلق إما لا مادة له، أو له مادة'], [3, 'الفصل الثالث: حكم الماء القليل'], [3, 'الفصل الرابع: حكم الماء المشتبه'], [3, 'الفصل الخامس: حكم الماء المضاف'], [2, 'المبحث الثاني: أحكام الخلوة'], [2, 'المبحث الثالث: الوضوء'], [3, 'الفصل الأول: أجزاء الوضوء'], [3, 'الفصل الثاني: أحكام الجبائر']];
const HITS = [[41, 'مسألة ٤٥: يعتبر في جريان حكم <mark>ماء المطر</mark> أن يصدق عرفاً أنّ النازل من السماء (ماء مطر)…'], [41, '…قطرات قليلة فلا يشمله حكم <mark>ماء المطر</mark>.'], [41, 'مسألة ٤٦: الفراش المتنجّس إذا تقاطر عليه <mark>المطر</mark> ونفذ في جميعه طهر الجميع…']];
const CATS = ['الكل', 'الفقه', 'أصول الفقه', 'الحديث الشريف', 'العقيدة', 'تفسير القرآن'];
const SHELVES = [['سماحة السيد السيستاني (دام ظله)', [435, 448, 820]], ['السيد الحكيم (قدس سره)', [7041, 7045, 7046, 7047, 7001, 7037, 7031, 7010, 7011, 7021, 7020, 7022]], ['أمهات الكتب', [1, 361, 357, 449, 446]]];
const SORTS = { lib: ['آخر ما فُتح', 'العنوان', 'المؤلف', 'التصنيف'], store: ['الأحدث', 'العنوان', 'المؤلف', 'التصنيف', 'اللغة', 'الناشر'] };
const sizeOf = (id, p) => id === 435 && p === 1 ? 3.9 : 4 + (id * 7 + p * 13) % 38;
const pagesOf = (id, p) => id === 435 && p === 1 ? 520 : id === 435 && p === 2 ? 516 : id === 435 && p === 3 ? 356 : 280 + (id + p * 37) % 340;

class App {
  constructor(el, cfg) {
    this.el = el; this.cfg = cfg;
    Object.assign(this, { view: 'masdar', tab: 'lib', doc: null, cur: 0, quiet: false, pop: false, tool: 'pen', col: { pen: COL.pen[1], hl: COL.hl[0], laser: COL.laser[0] }, barT: [...BAR0], boxT: [...BOX0], lzs: [], w: 5, ink: {}, redo: {}, kind: { pen: 'ink', eraser: 'part', shape: 'line', word: 'hl' }, ruler: null, sel: null, bms: new Set([41]), fingerDraws: false, snap: true, awake: true, conflict: false, libSort: 0, libCat: 'الكل', libQ: '', storeSort: 0, storeCat: 'الكل', storeQ: '', pagesTab: 'all', book: 435, dl: { '435:1': { st: 'done', p: 100 }, '448:1': { st: 'done', p: 100 }, '7045:1': { st: 'done', p: 100 }, '446:1': { st: 'done', p: 100 }, '1034:1': { st: 'done', p: 100 } }, queue: [], synced: '٩:٣٨' });
    this.hist = [{ id: 435, part: 1, pg: 41, of: 520 }, { id: 448, pg: 118, of: 544 }, { id: 7045, pg: 64, of: 310 }, { id: 446, part: 1, pg: 27, of: 409 }, { id: 1034, part: 1, pg: 76, of: 390 }, { id: 7041, part: 1, pg: 9, of: 480 }, { id: 361, part: 1, pg: 212, of: 640 }, { id: 449, pg: 88, of: 620 }, { id: 7011, part: 1, pg: 33, of: 410 }, { id: 1, part: 1, pg: 150, of: 560 }, { id: 357, part: 1, pg: 12, of: 500 }];
    this.lib = [{ id: 435, part: 1, pg: 41, of: 520 }, { id: 448, pg: 118, of: 544 }, { id: 7045, pg: 64, of: 310 }, { id: 446, part: 1, pg: 27, of: 409 }, { id: 7041, part: 1, pg: 9, of: 480, cloud: 1 }, { id: 1034, part: 1, pg: 76, of: 390 }];
    el.classList.add('app', cfg.plat, cfg.form);
    el.style.setProperty('--sb', cfg.solo ? 'max(env(safe-area-inset-top),8px)' : (cfg.form === 'tablet' ? '26px' : cfg.plat === 'ios' ? '54px' : '36px'));
    el.innerHTML = '<div class="host"></div><div class="ov"></div>';
    this.host = el.firstChild; this.ov = el.lastChild;
    el.addEventListener('click', e => {
      const t = e.target.closest('[data-a]');
      if (t && el.contains(t)) this[t.dataset.a]?.(t.dataset.p);
      else if (e.target.closest('button')) this.toast('تصميم فقط، يعمل في التطبيق الفعلي');
    });
    el.addEventListener('input', e => { const f = e.target.dataset.i; if (f) this[f](e.target.value); });
    el.addEventListener('change', e => { if (e.target.dataset.f && e.target.files[0]) this.addImage(e.target.files[0]); });
    el.addEventListener('pointerdown', e => { const c = e.target.closest('.tchip'); if (c) this.dragChip(e, c); });
    this.draw();
  }
  get tablet() { return this.cfg.form === 'tablet'; }
  title(e) { return BK[e.id].t + (e.part ? ' ' + n(e.part) : ''); }
  toast(s) {
    this.el.querySelector('.toast')?.remove();
    const d = document.createElement('div'); d.className = 'toast'; d.textContent = s; this.el.append(d);
    setTimeout(() => d.remove(), 1900);
  }
  /* التنقل */
  closeSheet() { this.ov.innerHTML = ''; }
  sheet(k, p) { this.pop = false; this.sk = k; this.sp = p; this.ov.innerHTML = `<div class="scrim" data-a="closeSheet"></div><div class="sheet" role="dialog"><div class="grab"></div>${this['s_' + k](p)}</div>`; this.tools(); }
  resheet() { if (this.ov.innerHTML) this.sheet(this.sk, this.sp); }
  show(view) { this.view = view; this.closeSheet(); this.quiet = false; this.pop = false; this.sel = null; this.draw(true); }
  toMasdar() { this.show('masdar'); }
  openInMasdar() { this.show('masdar'); this.toast('فُتحت الصفحة نفسها في المصدر'); }
  openPages(k) { this.pagesTab = k; this.sheet('pages'); }
  back() { this.show(this.doc?.from === 'masdar' ? 'masdar' : 'main'); }
  setTab(k) { this.tab = k; this.show('main'); }
  fromMasdar() { this.openDoc('masdar'); }
  openDoc(from) { this.doc = { key: 'book', title: 'منهاج الصالحين ١', from, of: 520, ar: 1000 / 1497, pages: [{ img: 'page1', no: 41 }, { img: 'page2', no: 42 }] }; this.cur = 0; this.show('write'); }
  openBook(id) {
    id = +id; this.closeSheet(); const e = this.lib.find(b => b.id === id);
    if (e?.cloud) { e.cloud = 0; this.draw(); this.toast('جارٍ تنزيل الكتاب…'); return; }
    const h = this.hist.find(b => b.id === id) || { id, pg: 1, of: pagesOf(id, 1) };
    this.hist = [h, ...this.hist.filter(b => b !== h)];
    if (id === 435) this.openDoc('main'); else this.toast('تصميم فقط: الصفحات التجريبية في منهاج الصالحين ١');
  }
  openNote(id) { const x = NOTES.find(y => y.id === id); this.doc = { key: id, title: x.t, from: 'main', ar: 210 / 297, pages: [{ tpl: x.tpl, ink: x.ink }] }; this.cur = 0; if (this.tool === 'word') this.tool = 'pen'; this.show('write'); }
  newPaper(tpl) { this.doc = { key: 'new' + Date.now(), title: 'ملاحظة جديدة', from: 'main', ar: 210 / 297, pages: [{ tpl }] }; this.cur = 0; if (this.tool === 'word') this.tool = 'pen'; this.show('write'); }
  goPage(i) { i = +i; const dir = i > this.cur ? 'next' : 'prev'; this.cur = i; this.sel = null; this.closeSheet(); this.draw(); this.host.querySelector('.pages')?.classList.add(dir); }
  jump() { const v = +this.ov.querySelector('.goto input').value.replace(/[٠-٩]/g, d => '٠١٢٣٤٥٦٧٨٩'.indexOf(d)); const i = this.doc.pages.findIndex(p => p.no === v); if (i >= 0) this.goPage(i); else this.toast('النموذج فيه الصفحتان ٤١ و٤٢ فقط'); }
  toggleBm() { const no = this.doc.pages[this.cur].no ?? 1; this.bms.has(no) ? this.bms.delete(no) : this.bms.add(no); this.closeSheet(); this.draw(); }
  flip(k) { this[k] = !this[k]; this.resheet(); if (this.view === 'write') this.tools(); }
  /* الأدوات */
  openTools() { this.quiet = false; this.applyQuiet(); }
  setTool(k) {
    if (k === 'ruler') { this.ruler = this.ruler === null ? 620 : null; this.pop = false; this.redrawAll(); this.tools(); return; }
    if (k === 'image') { this.pop = false; this.sheet('addimg'); return; }
    const same = this.tool === k;
    this.tool = k; this.sel = null;
    this.pop = this.hasTray(k) ? (same && this.pop === 'tray' ? false : 'tray') : false;
    this.tools(); this.markHand(); this.redrawAll();
  }
  hasTray(k) { return ['pen', 'hl', 'eraser', 'shape', 'word', 'text', 'pin', 'laser'].includes(k); }
  palKey() { return this.tool === 'hl' || (this.tool === 'word' && this.kind.word !== 'color') ? 'hl' : this.tool === 'laser' ? 'laser' : 'pen'; }
  more() { this.pop = this.pop === 'more' ? false : 'more'; this.tools(); }
  setColor(c) { this.col[this.palKey()] = c; this.pop = false; this.tools(); }
  setCustom(c) { this.col[this.palKey()] = c; }
  setKind(v) { this.kind[this.tool] = v; this.tools(); }
  setW(w) { this.w = +w; this.tools(); }
  key(i = this.cur) { return `${this.doc.key}:${i}`; }
  undo() { const k = this.key(), l = this.list(k); if (l.length) { (this.redo[k] ||= []).push(l.pop()); this.sel = null; this.redrawAll(); this.tools(); } }
  redoIt() { const k = this.key(), r = this.redo[k]; if (r?.length) { this.list(k).push(r.pop()); this.redrawAll(); this.tools(); } }
  markHand() { this.host.querySelector('.view')?.classList.toggle('hand', this.tool === 'hand'); }
  applyQuiet() {
    this.el.classList.toggle('quiet', this.quiet);
    if (this.quiet && this.pop) { this.pop = false; this.tools(); }
    this.cfg.onStep?.(this.view === 'masdar' ? 'masdar' : this.view === 'book' ? 'book' : this.view === 'main' ? this.tab : this.doc.key !== 'book' ? 'write' : this.quiet ? 'quiet' : 'write');
  }
  /* الرسم */
  draw(anim) {
    const v = this.view, sc = this.host.querySelector('.scroll,.write .desk')?.scrollTop;
    this.el.classList.toggle('onpaper', v === 'write');
    this.host.innerHTML = `<div class="view ${anim ? 'in' : ''} ${v === 'write' ? 'write' : ''}">${this['v_' + v]()}</div>${v === 'main' ? this.navbar() : ''}${this.cfg.solo ? '' : this.status() + '<div class="homebar"></div>'}`;
    this.applyQuiet();
    if (v === 'write') { this.tools(); this.bindInk(); this.markHand(); }
    if (!anim && sc) { const s = this.host.querySelector('.scroll,.write .desk'); if (s) s.scrollTop = sc; }
  }
  status() {
    const c = 'currentColor';
    return `<div class="sb"><span>٩:٤١</span><span class="r"><svg viewBox="0 0 18 12"><path fill="${c}" d="M0 8h3v4H0zM5 5.500h3V12H5zM10 3h3v9h-3zM15 0h3v12h-3z"/></svg><svg viewBox="0 0 26 12"><rect x=".5" y=".5" width="22" height="11" rx="3" fill="none" stroke="${c}" opacity=".6"/><rect x="2" y="2" width="16" height="8" rx="1.500" fill="${c}"/><path fill="${c}" d="M24 4v4a2 2 0 0 0 0-4z"/></svg></span></div>`;
  }
  navbar() {
    const b = (k, i, s) => `<button class="${this.tab === k ? 'on' : ''}" data-a="setTab" data-p="${k}">${ic(i)}${s}</button>`;
    return `<nav class="nav-b glass">${b('lib', 'lib', 'كتبي')}${b('store', 'store', 'الكتب')}${b('notes', 'note', 'ملاحظاتي')}</nav><button class="star" data-a="sheet" data-p="new" aria-label="جديد">${STAR}${ic('plus')}</button>`;
  }
  pageHTML(doc, i, live) {
    const p = doc.pages[i], no = p.no ?? 1;
    return `<div class="pages" style="--ar:${doc.ar}"><div class="page" data-i="${i}">${p.img ? `<img src="${A[p.img]}" alt="صفحة ${n(p.no)}">` : paperSVG(p.tpl, p.ink)}${live ? `<div class="imgs"></div><canvas width="2000" height="${Math.round(2000 / doc.ar)}"></canvas><div class="items"></div>${this.bms.has(no) ? `<span class="ribbon on">${ic('bm')}</span>` : ''}` : ''}</div></div>`;
  }
  /* المصدر */
  v_masdar() {
    const doc = { ar: 1000 / 1497, pages: [{ img: 'page1', no: 41 }] };
    return `<header class="mtop"><div class="bar"><div><button class="ib" aria-label="القائمة">${ic('menu')}</button><button class="ib" aria-label="الإعدادات">${ic('gear')}</button><button class="ib" aria-label="إشارة">${ic('fav')}</button><button class="ib" aria-label="بحث">${ic('search')}</button></div><button class="ib" aria-label="رجوع">${ic('back')}</button></div><p>منهاج الصالحين ١</p></header>
      <div class="mbody"><div class="desk">${this.pageHTML(doc, 0, false)}</div><button class="penbtn" data-a="fromMasdar">${ic('pen')}اكتب على هذه الصفحة</button></div>`;
  }
  /* الكتابة */
  v_write() {
    const conf = this.conflict ? `<div class="conflict glass"><b>كُتب على هذه الصفحة من جهازين</b><p>تابلت أندرويد، اليوم ٨:١٥</p><div class="r"><button>هذا الجهاز</button><button>تابلت أندرويد</button><button>دمج</button><button class="pri" data-a="settle">اعتماد ما يظهر الآن</button></div></div>` : '';
    const book = this.doc.key === 'book', on = this.bms.has(this.doc.pages[this.cur].no ?? 1);
    const ib = (a, p, i, s, c = '') => `<button class="ib ${c}" data-a="${a}" data-p="${p}" title="${s}" aria-label="${s}">${ic(i)}</button>`;
    return `<div class="desk">${this.pageHTML(this.doc, this.cur, true)}</div><div class="wtop"><button class="gp glass ib" data-a="back" title="رجوع" aria-label="رجوع">${ic('back')}</button>${book ? `<button class="msd" data-a="openInMasdar" title="فتح في المصدر" aria-label="فتح في المصدر"><img src="${A['masdar-icon']}" alt=""></button>` : ''}<span class="sp"></span><div class="toolrow glass"></div><span class="sp"></span><div class="gp glass">${ib('sheet', 'recent', 'recent', 'آخر ١٠ كتب')}${book ? ib('sheet', 'toc', 'toc', 'الفهرس') + ib('sheet', 'find', 'search', 'بحث') : ''}${ib('toggleBm', '', 'bm', 'علامة', on ? 'mk' : '')}${ib('sheet', 'menu', 'more', 'المزيد')}</div><span class="brk"></span></div>
      ${conf}<button class="pnum glass" data-a="openPages" data-p="all"></button><div class="tools-host"></div>`;
  }
  settle() { this.conflict = false; this.draw(); this.toast('اعتُمدت هذه الصفحة.'); }
  tools() {
    const row = this.host.querySelector('.toolrow'), h = this.host.querySelector('.tools-host'); if (!row) return;
    const book = this.doc.key === 'book', okT = k => k !== 'word' || book;
    const isOn = k => this.tool === k || (k === 'ruler' && this.ruler !== null), inBox = this.boxT.includes(this.tool);
    const key = this.palKey(), c = this.col[key], colored = this.hasTray(this.tool) && this.tool !== 'eraser';
    row.innerHTML = `${this.barT.filter(okT).map(k => `<button class="tl ${isOn(k) ? 'on' : ''}" data-a="setTool" data-p="${k}" title="${ALLT[k]}" aria-label="${ALLT[k]}">${ic(k)}</button>`).join('')}<button class="tl ${inBox ? 'on' : ''}" data-a="more" title="مربع الأدوات" aria-label="مربع الأدوات">${ic(inBox ? this.tool : 'grid')}</button><span class="sep"></span><button class="tl" data-a="undo" title="تراجع" aria-label="تراجع">${ic('undo')}</button><button class="tl" data-a="redoIt" title="إعادة" aria-label="إعادة">${ic('redo')}</button>`;
    let tray = '';
    if (this.pop === 'more') {
      const xs = this.boxT.filter(okT);
      tray = `<div class="tray glass">${xs.length ? `<div class="xgrid" style="--c:${Math.min(3, xs.length)}">${xs.map(k => `<button class="${isOn(k) ? 'on' : ''}" data-a="setTool" data-p="${k}">${ic(k)}${ALLT[k]}</button>`).join('')}</div>` : ''}<button class="tset" data-a="sheet" data-p="toolset">${ic('gear')}إعدادات الأدوات</button></div>`;
    } else if (this.pop === 'tray') {
      const kinds = KINDS[this.tool], drawn = this.tool === 'pen' || this.tool === 'shape';
      tray = `<div class="tray glass">${kinds ? `<div class="kinds">${kinds.map(([k, s]) => `<button class="${this.kind[this.tool] === k ? 'on' : ''}" data-a="setKind" data-p="${k}">${s}</button>`).join('')}</div>` : ''}${colored ? `<div class="r">${COL[key].map(x => `<button class="cd ${x === c ? 'on' : ''}" style="background:${x}" data-a="setColor" data-p="${x}" aria-label="لون"></button>`).join('')}<label class="cd add" aria-label="إضافة لون"><input type="color" data-i="setCustom"></label></div>` : ''}${drawn ? `<div class="r">${[3, 5, 8].map(w => `<button class="wd ${this.w === w ? 'on' : ''}" data-a="setW" data-p="${w}" aria-label="سماكة"><i style="height:${w / 2 + 1}px"></i></button>`).join('')}</div><div class="swr"><span>استقامة تلقائية عند التوقف</span><button class="tog ${this.snap ? 'on' : ''}" data-a="flipSnap" aria-label="استقامة تلقائية"></button></div><div class="swr"><span>الإصبع يرسم</span><button class="tog ${this.fingerDraws ? 'on' : ''}" data-a="flipFinger" aria-label="الإصبع يرسم"></button></div>` : ''}</div>`;
    }
    const sel = this.sel ? `<div class="selbar glass"><button data-a="selDel">حذف المحدد</button><button data-a="selDup">تكرار المحدد</button></div>` : '';
    h.innerHTML = `${tray}${sel}<button class="dot glass" data-a="openTools" aria-label="الأدوات" style="color:var(--blue)">${ic(this.tool)}</button>`;
    this.pnum();
  }
  /* إعدادات الأدوات */
  zones() {
    const chips = l => l.map(k => `<div class="tchip" data-k="${k}">${ic(k)}<span>${ALLT[k]}</span></div>`).join('');
    return `<div class="tzl">في الشريط</div><div class="tz" data-z="barT">${chips(this.barT)}</div><div class="tzl">داخل المربع</div><div class="tz" data-z="boxT">${chips(this.boxT)}</div>`;
  }
  s_toolset() { return `<h3>إعدادات الأدوات</h3><p class="t">اسحب الأداة بين الشريط والمربع أو غيّر ترتيبها، أو اضغطها لنقلها.</p><div class="tzones">${this.zones()}</div><div class="btns"><button class="mini" data-a="resetTools">الترتيب الأصلي</button><button class="mini pri" data-a="closeSheet">تم</button></div>`; }
  refreshZones() { const z = this.ov.querySelector('.tzones'); if (z) z.innerHTML = this.zones(); this.tools(); }
  resetTools() { this.barT = [...BAR0]; this.boxT = [...BOX0]; this.refreshZones(); }
  dragChip(e, chip) {
    e.preventDefault();
    const k = chip.dataset.k, sx = e.clientX, sy = e.clientY; let ghost = null;
    const mv = ev => {
      if (!ghost && Math.hypot(ev.clientX - sx, ev.clientY - sy) > 6) {
        ghost = chip.cloneNode(true); ghost.classList.add('ghost'); document.body.append(ghost); chip.style.opacity = .3;
      }
      if (ghost) { ghost.style.left = ev.clientX + 'px'; ghost.style.top = ev.clientY + 'px'; }
    };
    const up = ev => {
      removeEventListener('pointermove', mv); removeEventListener('pointerup', up); removeEventListener('pointercancel', up);
      const from = this.barT.includes(k) ? 'barT' : 'boxT';
      if (!ghost) { const to = from === 'barT' ? 'boxT' : 'barT'; this[from].splice(this[from].indexOf(k), 1); this[to].push(k); this.refreshZones(); return; }
      ghost.remove();
      const el = document.elementFromPoint(ev.clientX, ev.clientY), zone = el?.closest('.tz');
      if (zone) {
        const to = zone.dataset.z, others = [...zone.querySelectorAll('.tchip')].filter(c => c.dataset.k !== k);
        let at = others.length;
        for (let i = 0; i < others.length; i++) { const r = others[i].getBoundingClientRect(); if (ev.clientY < r.bottom && ev.clientX > r.left + r.width / 2) { at = i; break; } }
        this[from].splice(this[from].indexOf(k), 1); this[to].splice(at, 0, k);
      }
      this.refreshZones();
    };
    addEventListener('pointermove', mv); addEventListener('pointerup', up); addEventListener('pointercancel', up);
  }
  /* الصور */
  s_addimg() { return `<h3>إضافة صورة</h3><div class="card"><label class="row">${ic('image')}<span>من المعرض</span><input type="file" accept="image/*" data-f="1" hidden></label><label class="row">${ic('save')}<span>من الكاميرا</span><input type="file" accept="image/*" capture="environment" data-f="1" hidden></label></div>`; }
  addImage(file) {
    this.closeSheet();
    const src = URL.createObjectURL(file), im = new Image();
    im.onload = () => {
      const c = this.host.querySelector('.page canvas'), d = c.closest('.desk').getBoundingClientRect(), r = c.getBoundingClientRect(), k = 1000 / r.width;
      const w = 520, h = Math.min(760, w * im.naturalHeight / im.naturalWidth), x = 240, y = Math.max(30, ((d.top + d.bottom) / 2 - r.top) * k - h / 2);
      const it = { k: 'image', src, a: [x, y], b: [x + w, y + h] };
      this.list(this.key()).push(it); this.tool = 'lasso'; this.sel = { i: this.cur, items: [it] }; this.markHand(); this.redrawAll(); this.tools();
    };
    im.src = src;
  }
  /* الليزر */
  runLaser(cv, i) {
    if (this.lz) return;
    const tick = () => {
      const now = performance.now(); this.lzs = this.lzs.filter(s => !s.t || now - s.t < 900);
      this.paint(cv, i); this.lz = this.lzs.length ? requestAnimationFrame(tick) : 0;
    };
    this.lz = requestAnimationFrame(tick);
  }
  pnum() {
    const el = this.host.querySelector('.pnum'); if (!el) return;
    const d = this.doc, no = d.pages[this.cur].no ?? this.cur + 1;
    el.innerHTML = `<b>${n(no)}</b>${d.of ? ` / ${n(d.of)}` : ''}`;
  }
  flipFinger() { this.fingerDraws = !this.fingerDraws; this.tools(); }
  flipSnap() { this.snap = !this.snap; this.tools(); }
  /* الحبر */
  list(k) {
    if (!this.ink[k]) {
      this.ink[k] = [];
      if (k === 'book:0') {
        const r = DATA.pages.page1.rows, mid = i => (r[i][0] + r[i][1]) / 2, y = mid(4), e = [];
        for (let a = 0; a <= 6.4; a += .25) e.push([880 + 92 * Math.cos(a), y + 30 * Math.sin(a)]);
        this.ink[k].push({ k: 'hl', c: COL.hl[0], w: r[3][1] - r[3][0] + 10, p: [[958, mid(3)], [395, mid(3)]] }, { k: 'pen', kind: 'ink', c: COL.pen[1], w: 4, p: e }, { k: 'pen', kind: 'ink', c: COL.pen[2], w: 4, p: [[800, r[9][1] + 7], [640, r[9][1] + 10], [480, r[9][1] + 6], [330, r[9][1] + 9]] }, { k: 'text', c: COL.pen[2], s: 'قارن بالمسألة ٤٩', x: 240, y: r[5][1] - 2, z: 36, f: 'ruq' }, { k: 'pin', x: 26, y: r[7][0] + 14, s: 'العبرة بالصدق العرفي، لا بكثرة القطرات.' });
      }
    }
    return this.ink[k];
  }
  box(s) {
    if (s.p) { const xs = s.p.map(q => q[0]), ys = s.p.map(q => q[1]); return [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)]; }
    if (s.a) return [Math.min(s.a[0], s.b[0]), Math.min(s.a[1], s.b[1]), Math.max(s.a[0], s.b[0]), Math.max(s.a[1], s.b[1])];
    return [s.x - 120, s.y - 34, s.x + 120, s.y + 8];
  }
  shift(s, dx, dy) { if (s.p) s.p = s.p.map(q => [q[0] + dx, q[1] + dy]); else if (s.a) { s.a = [s.a[0] + dx, s.a[1] + dy]; s.b = [s.b[0] + dx, s.b[1] + dy]; } else { s.x += dx; s.y += dy; } }
  paint(cv, i) {
    const g = cv.getContext('2d'); g.setTransform(1, 0, 0, 1, 0, 0); g.clearRect(0, 0, cv.width, cv.height); g.setTransform(2, 0, 0, 2, 0, 0);
    for (const s of this.list(this.key(i))) {
      if (s.k === 'pin' || s.k === 'image' || (s.k === 'tape' && !s.live)) continue;
      g.save();
      g.lineJoin = 'round'; g.lineCap = 'round'; g.strokeStyle = s.c || '#000'; g.fillStyle = s.c || '#000'; g.lineWidth = s.w || 4;
      if (s.k === 'text') { g.font = s.f === 'ruq' ? `${s.z}px 'Aref Ruqaa',serif` : `700 ${s.z}px Muna,sans-serif`; g.textAlign = 'center'; g.direction = 'rtl'; g.fillText(s.s, s.x, s.y); }
      else if (s.k === 'tape') { g.strokeStyle = '#C9B98E'; g.setLineDash([10, 8]); g.strokeRect(s.a[0], s.a[1], s.b[0] - s.a[0], s.b[1] - s.a[1]); }
      else if (s.k === 'shape') this.shapePath(g, s);
      else if (s.k === 'mark') {
        const [x1, , x2] = this.box(s), y1 = s.y1 ?? s.a[1], y2 = s.y2 ?? s.b[1];
        if (s.st === 'hl' || s.st === 'comment' || s.st === 'color') { g.globalAlpha = s.st === 'color' ? .3 : .55; g.fillRect(x1, y1 - 4, x2 - x1, y2 - y1 + 8); }
        else { g.strokeStyle = COL.pen[2]; g.lineWidth = 4; const y = s.st === 'under' ? y2 + 7 : (y1 + y2) / 2; g.beginPath(); g.moveTo(x1, y); g.lineTo(x2, y); g.stroke(); }
      } else if (s.kind === 'cal') {
        for (let j = 1; j < s.p.length; j++) { const [a, b] = [s.p[j - 1], s.p[j]], an = Math.atan2(b[1] - a[1], b[0] - a[0]); g.lineWidth = s.w * (.5 + 1.5 * Math.abs(Math.sin(an - .8))); g.beginPath(); g.moveTo(...a); g.lineTo(...b); g.stroke(); }
      } else {
        if (s.k === 'hl') { g.lineCap = 'butt'; g.globalAlpha = .55; }
        if (s.kind === 'pencil') { g.globalAlpha = .62; g.lineWidth = s.w * .8; }
        if (s.k === 'eraser') g.globalCompositeOperation = 'destination-out';
        g.beginPath(); g.moveTo(...s.p[0]);
        for (let j = 1; j < s.p.length - 1; j++) g.quadraticCurveTo(s.p[j][0], s.p[j][1], (s.p[j][0] + s.p[j + 1][0]) / 2, (s.p[j][1] + s.p[j + 1][1]) / 2);
        g.lineTo(...s.p[s.p.length - 1]); g.stroke();
      }
      g.restore();
    }
    const now = performance.now();
    for (const s of this.lzs) {
      if (s.p.length < 2) continue;
      g.save(); g.globalAlpha = s.t ? Math.max(0, 1 - (now - s.t) / 900) : 1; g.strokeStyle = s.c; g.shadowColor = s.c; g.shadowBlur = 22; g.lineWidth = 6; g.lineCap = 'round'; g.lineJoin = 'round';
      g.beginPath(); g.moveTo(...s.p[0]); s.p.forEach(q => g.lineTo(...q)); g.stroke(); g.restore();
    }
    if (this.lasso?.length > 1) { g.save(); g.setLineDash([12, 10]); g.strokeStyle = '#1C4F92'; g.lineWidth = 3; g.beginPath(); g.moveTo(...this.lasso[0]); this.lasso.forEach(q => g.lineTo(...q)); g.stroke(); g.restore(); }
    if (this.sel?.i === i) { const b = this.selBox(); g.save(); g.setLineDash([12, 10]); g.strokeStyle = '#1C4F92'; g.lineWidth = 3; g.strokeRect(b[0] - 10, b[1] - 10, b[2] - b[0] + 20, b[3] - b[1] + 20); g.setLineDash([]); if (this.sel.items.length === 1 && this.sel.items[0].k === 'image') { g.fillStyle = '#1C4F92'; g.beginPath(); g.arc(b[2] + 10, b[3] + 10, 15, 0, 7); g.fill(); } g.restore(); }
  }
  shapePath(g, s) {
    const [x1, y1] = s.a, [x2, y2] = s.b; g.beginPath();
    if (s.s === 'rect') g.rect(x1, y1, x2 - x1, y2 - y1);
    else if (s.s === 'ellipse') g.ellipse((x1 + x2) / 2, (y1 + y2) / 2, Math.abs(x2 - x1) / 2, Math.abs(y2 - y1) / 2, 0, 0, 7);
    else if (s.s === 'tri') { g.moveTo((x1 + x2) / 2, y1); g.lineTo(x2, y2); g.lineTo(x1, y2); g.closePath(); }
    else { g.moveTo(x1, y1); g.lineTo(x2, y2); if (s.s === 'arrow') { const an = Math.atan2(y2 - y1, x2 - x1), h = 26; for (const d of [.45, -.45]) { g.moveTo(x2, y2); g.lineTo(x2 - h * Math.cos(an + d), y2 - h * Math.sin(an + d)); } } }
    g.stroke();
  }
  selBox() { const bs = this.sel.items.map(s => this.box(s)); return [Math.min(...bs.map(b => b[0])), Math.min(...bs.map(b => b[1])), Math.max(...bs.map(b => b[2])), Math.max(...bs.map(b => b[3]))]; }
  selDel() { const l = this.list(this.key()); this.sel.items.forEach(s => l.splice(l.indexOf(s), 1)); this.sel = null; this.redrawAll(); this.tools(); }
  selDup() { const l = this.list(this.key()), c = this.sel.items.map(s => { const d = structuredClone(s); this.shift(d, 30, 30); return d; }); l.push(...c); this.sel.items = c; this.redrawAll(); }
  redrawAll() {
    const pg = this.host.querySelector('.page'), c = pg?.querySelector('canvas'); if (!c) return;
    const i = +pg.dataset.i; this.paint(c, i);
    const W = c.width / 2, H = c.height / 2, its = this.list(this.key(i));
    pg.querySelector('.imgs').innerHTML = its.filter(s => s.k === 'image').map(s => `<img src="${s.src}" alt="" style="left:${s.a[0] / W * 100}%;top:${s.a[1] / H * 100}%;width:${(s.b[0] - s.a[0]) / W * 100}%;height:${(s.b[1] - s.a[1]) / H * 100}%">`).join('');
    pg.querySelector('.items').innerHTML = its.map((s, j) => s.k === 'pin' ? `<button class="pinm" style="left:${s.x / W * 100}%;top:${s.y / H * 100}%;${s.c ? `background:${s.c}` : ''}" data-a="sheet" data-p="pin:${j}" aria-label="ملاحظة">${ic('pin')}</button>` : s.k === 'tape' && !s.live ? `<button class="tapeb ${s.open ? 'open' : ''}" style="left:${Math.min(s.a[0], s.b[0]) / W * 100}%;top:${Math.min(s.a[1], s.b[1]) / H * 100}%;width:${Math.abs(s.b[0] - s.a[0]) / W * 100}%;height:${Math.abs(s.b[1] - s.a[1]) / H * 100}%" data-a="tapeFlip" data-p="${j}" aria-label="شريط"></button>` : '').join('') + (this.ruler !== null ? `<div class="ruler" style="top:${this.ruler / H * 100}%"><span>٠°</span></div>` : '');
    const r = pg.querySelector('.ruler');
    if (r) r.addEventListener('pointerdown', e => {
      r.setPointerCapture(e.pointerId);
      const mv = ev => { const b = c.getBoundingClientRect(); this.ruler = Math.max(20, Math.min(H - 80, (ev.clientY - b.top) * H / b.height)); r.style.top = this.ruler / H * 100 + '%'; };
      r.addEventListener('pointermove', mv); r.addEventListener('pointerup', () => r.removeEventListener('pointermove', mv), { once: true });
    });
  }
  tapeFlip(j) { const s = this.list(this.key())[+j]; s.open = !s.open; this.redrawAll(); }
  bindInk() {
    this.redrawAll();
    const cv = this.host.querySelector('.page canvas'), i = +cv.parentNode.dataset.i, key = this.key(i);
    let s = null, st = null, q = null, moved = 0, mode = '', cy = 0;
    const desk = cv.closest('.desk');
    const at = e => { const r = cv.getBoundingClientRect(); return [(e.clientX - r.left) * cv.width / 2 / r.width, (e.clientY - r.top) * cv.height / 2 / r.height]; };
    const snapY = y => this.ruler !== null && Math.abs(y - this.ruler) < 34 ? this.ruler : y;
    cv.addEventListener('pointerdown', e => {
      if (this.pop) { this.pop = false; this.tools(); }
      cv.setPointerCapture(e.pointerId); st = q = at(e); moved = 0; s = null; mode = ''; cy = e.clientY;
      const t = this.tool, c = this.col[t === 'hl' ? 'hl' : 'pen'];
      if (t === 'laser') s = { k: 'laser', c: this.col.laser, p: [st] };
      if (t === 'pen') s = { k: 'pen', kind: this.kind.pen, c, w: this.w, p: [[st[0], snapY(st[1])]] };
      if (t === 'hl') s = { k: 'hl', c, w: 30, p: [[st[0], snapY(st[1])]] };
      if (t === 'eraser') { if (this.kind.eraser === 'part') s = { k: 'eraser', w: 36, p: [st] }; else mode = 'wipe'; }
      if (t === 'shape') s = { k: 'shape', s: this.kind.shape, c, w: this.w, a: st, b: st };
      if (t === 'tape') s = { k: 'tape', a: st, b: st, live: 1 };
      if (t === 'word') s = { k: 'mark', st: this.kind.word, c: this.col[this.kind.word === 'color' ? 'pen' : 'hl'], a: st, b: st };
      if (t === 'lasso') { const one = this.sel?.items.length === 1 && this.sel.items[0].k === 'image' ? this.sel.items[0] : null; if (one && Math.hypot(st[0] - one.b[0] - 10, st[1] - one.b[1] - 10) < 60) mode = 'size'; else if (this.sel && (() => { const b = this.selBox(); return st[0] > b[0] - 10 && st[0] < b[2] + 10 && st[1] > b[1] - 10 && st[1] < b[3] + 10; })()) mode = 'move'; else { this.sel = null; this.lasso = [st]; this.tools(); mode = 'loop'; } }
    });
    cv.addEventListener('pointermove', e => {
      if (!st) return;
      if (this.tool === 'hand') { desk.scrollTop -= e.clientY - cy; cy = e.clientY; }
      const p = at(e), last = q; q = p; moved = Math.max(moved, Math.hypot(p[0] - st[0], p[1] - st[1]));
      if (moved <= 8) return;
      if ((s || mode === 'wipe') && !this.quiet) { this.quiet = true; this.applyQuiet(); }
      const l = this.list(key);
      if (s?.k === 'laser') { if (!this.lzs.includes(s)) this.lzs.push(s); s.p.push(p); this.runLaser(cv, i); return; }
      if (s) {
        if (!l.includes(s)) { l.push(s); this.redo[key] = []; }
        if (s.p) s.p.push(this.tool === 'eraser' ? p : [p[0], snapY(p[1])]); else s.b = p;
      }
      if (mode === 'wipe') { for (let j = l.length - 1; j >= 0; j--) { const it = l[j], b = this.box(it); if (it.k !== 'pin' && it.k !== 'eraser' && it.k !== 'image' && p[0] > b[0] - 14 && p[0] < b[2] + 14 && p[1] > b[1] - 14 && p[1] < b[3] + 14) l.splice(j, 1); } }
      if (mode === 'loop') this.lasso.push(p);
      if (mode === 'move') { this.sel.items.forEach(it => this.shift(it, p[0] - last[0], p[1] - last[1])); this.redrawAll(); return; }
      if (mode === 'size') { const it = this.sel.items[0], r = (it.b[1] - it.a[1]) / (it.b[0] - it.a[0]), w = Math.max(120, p[0] - it.a[0]); it.b = [it.a[0] + w, it.a[1] + w * r]; this.redrawAll(); return; }
      this.paint(cv, i);
    });
    const up = () => {
      if (!st) return;
      const dx = q[0] - st[0], l = this.list(key), tap = moved <= 8, tool = this.tool;
      if (s?.k === 'laser') { s.t = performance.now(); this.runLaser(cv, i); }
      const hitImg = tap && tool === 'lasso' ? [...l].reverse().find(it => it.k === 'image' && st[0] > it.a[0] && st[0] < it.b[0] && st[1] > it.a[1] && st[1] < it.b[1]) : null;
      if (hitImg) { this.sel = { i, items: [hitImg] }; this.tools(); this.paint(cv, i); }
      else if (tap) {
        if (tool === 'text' || tool === 'pin') this.sheet('input', { kind: tool, x: st[0], y: st[1] });
        else if (this.sel) { this.sel = null; this.tools(); this.paint(cv, i); } else { this.quiet = !this.quiet; this.applyQuiet(); }
      } else {
        if (tool === 'hand' && Math.abs(dx) > 130) { const d = dx > 0 ? 1 : -1, to = this.cur + d; if (this.doc.pages[to]) this.goPage(to); st = null; return; }
        if (mode === 'loop') {
          const b = this.box({ p: this.lasso }), hit = l.filter(it => { if (it.k === 'pin') return false; const x = this.box(it), cx = (x[0] + x[2]) / 2, cy = (x[1] + x[3]) / 2; return cx > b[0] && cx < b[2] && cy > b[1] && cy < b[3]; });
          this.lasso = null; this.sel = hit.length ? { i, items: hit } : null; this.tools(); this.paint(cv, i);
        }
        if (s?.k === 'tape') { delete s.live; this.redrawAll(); }
        if (s?.k === 'mark') {
          const rows = DATA.pages[this.doc.pages[i].img]?.rows;
          if (rows) { const r = rows.reduce((a, b) => Math.abs((b[0] + b[1]) / 2 - s.a[1]) < Math.abs((a[0] + a[1]) / 2 - s.a[1]) ? b : a); s.y1 = r[0]; s.y2 = r[1]; }
          this.paint(cv, i);
          if (s.st === 'comment') this.sheet('input', { kind: 'pin', x: Math.min(s.a[0], s.b[0]), y: s.y1 ?? s.a[1], title: 'إضافة تعليق' });
        }
      }
      st = null; s = null; mode = '';
    };
    cv.addEventListener('pointerup', up); cv.addEventListener('pointercancel', up);
  }
  /* كتبي */
  v_main() {
    return `<div class="scroll">${this['t_' + this.tab]()}</div>`;
  }
  avatar() { return `<div class="hacts"><button class="hbtn" data-a="sheet" data-p="recent" title="آخر ١٠ كتب" aria-label="آخر ١٠ كتب">${ic('recent')}</button><button class="hbtn" data-a="sheet" data-p="account" title="الحساب" aria-label="الحساب">${ic('user')}<i></i></button></div>`; }
  t_lib() {
    return `<header class="hero"><div class="wrap"><div class="hbar">${logo(44)}<h2>نوتس<small>قلم المصدر</small></h2>${this.avatar()}</div></div></header>
      <div class="panel"><div class="wrap">${this.conflict ? `<button class="banner-row" data-a="openConflict">${ic('warn')}<span>صفحة تنتظر اختيارك</span></button>` : ''}<div class="tools" style="margin:0"><div class="pills" style="flex:1;margin:0 -18px 0 0;min-width:0;padding:2px 18px 4px 6px">${CATS.map(c => `<button class="pl ${this.libCat === c ? 'on' : ''}" data-a="setLibCat" data-p="${c}">${c}</button>`).join('')}</div><button class="sq" data-a="sheet" data-p="libSort" aria-label="الترتيب">${ic('sort')}</button></div>
        <div class="sect"><h3>${this.libCat === 'الكل' ? 'كل الكتب' : this.libCat} <small>(${n(this.lib.filter(e => this.libCat === 'الكل' || BK[e.id].cat === this.libCat).length)})</small></h3></div>
        <div class="tools"><label class="search lt">${ic('search')}<input data-i="libSearch" placeholder="ابحث في كتبك" value="${esc(this.libQ)}"></label></div>
        <div class="libgrid">${this.libGrid()}</div></div></div>`;
  }
  libItems() {
    let l = this.lib.filter(e => (this.libCat === 'الكل' || BK[e.id].cat === this.libCat) && (BK[e.id].t + BK[e.id].a).includes(this.libQ));
    const by = [null, e => BK[e.id].t, e => BK[e.id].a, e => BK[e.id].cat][this.libSort];
    if (by) l = [...l].sort((a, b) => by(a).localeCompare(by(b), 'ar'));
    return l;
  }
  libGrid() {
    const l = this.libItems();
    if (!l.length) return `<p style="color:var(--muted);font-size:14px">${this.libQ ? 'لا يوجد كتاب بهذا البحث.' : 'لا توجد كتب في هذا التصنيف بعد.'}</p>`;
    return `<div class="grid">${l.map(e => `<div class="it"><button data-a="openBook" data-p="${e.id}">${cov(e.id, `<div class="pb"><i style="width:${Math.round(e.pg / e.of * 100)}%"></i></div>${e.cloud ? `<span class="badge">${ic('cloud')}</span>` : ''}`)}<b>${this.title(e)}</b><small>${e.cloud ? 'في حسابك، اضغط لتنزيله' : BK[e.id].as}</small></button><button class="mo" data-a="sheet" data-p="bookAct:${e.id}" aria-label="خيارات">${ic('more')}</button></div>`).join('')}</div>`;
  }
  setLibCat(c) { this.libCat = c; this.draw(); }
  libSearch(v) { this.libQ = v; this.host.querySelector('.libgrid').innerHTML = this.libGrid(); }
  openConflict() { this.conflict = true; this.openDoc('main'); }
  t_notes() {
    return `<header class="hero"><div class="wrap"><div class="hbar"><h2>ملاحظاتي<small>أوراقك خارج الكتب</small></h2>${this.avatar()}</div></div></header>
      <div class="panel"><div class="wrap"><div class="grid notes">${NOTES.map(x => `<div class="it"><button data-a="openNote" data-p="${x.id}"><div class="pv">${paperSVG(x.tpl, x.ink)}</div><b>${x.t}</b><small>${x.d}</small></button></div>`).join('')}</div></div></div>`;
  }
  /* المتجر */
  t_store() {
    const shelf = this.storeCat === 'الكل' && !this.storeQ && !this.storeSort;
    return `<header class="hero"><div class="wrap"><div class="hbar"><h2>الكتب<small>تصفّح وحمّل ما تريد</small></h2>${this.avatar()}</div><label class="search">${ic('search')}<input data-i="storeSearch" placeholder="ابحث بالعنوان أو المؤلف أو المحقق" value="${esc(this.storeQ)}"></label></div></header>
      <div class="panel"><div class="wrap"><div class="tools" style="margin:0"><div class="pills" style="flex:1;margin:0 -18px 0 0;min-width:0;padding:2px 18px 4px 6px">${CATS.map(c => `<button class="pl ${this.storeCat === c ? 'on' : ''}" data-a="setStoreCat" data-p="${c}">${c}</button>`).join('')}</div><button class="sq" data-a="sheet" data-p="storeSort" aria-label="الترتيب">${ic('sort')}</button></div><div class="storebody">${shelf ? this.shelves() : this.storeGrid()}</div></div></div>`;
  }
  bookBtn(id) { return `<button class="sb2" data-a="openDetail" data-p="${id}">${cov(id, this.owned(id) ? `<span class="badge">${ic('check')}</span>` : '')}<b>${BK[id].t}</b><small>${BK[id].as}</small></button>`; }
  owned(id) { return this.lib.some(e => e.id === id); }
  shelves() {
    return `${SHELVES.map(([h, ids]) => `<div class="sect"><h3>${h}</h3></div><div class="hs shelf">${ids.map(id => this.bookBtn(id)).join('')}</div>`).join('')}`;
  }
  storeItems() {
    let l = Object.keys(BK).map(Number).filter(id => (this.storeCat === 'الكل' || BK[id].cat === this.storeCat) && (BK[id].t + BK[id].a).includes(this.storeQ));
    const by = [null, id => BK[id].t, id => BK[id].a, id => BK[id].cat, () => '', id => BK[id].pub][this.storeSort];
    if (by) l.sort((a, b) => by(a).localeCompare(by(b), 'ar'));
    return l;
  }
  storeGrid() { const l = this.storeItems(); return l.length ? `<div class="grid" style="margin-top:16px">${l.map(id => `<div class="it">${this.bookBtn(id).replace('class="sb2"', 'class="sb2" style="width:100%"')}</div>`).join('')}</div>` : '<p style="color:var(--muted);font-size:14px;margin-top:16px">لا يوجد كتاب بهذا البحث.</p>'; }
  storeSearch(v) { this.storeQ = v; this.host.querySelector('.storebody').innerHTML = v || this.storeCat !== 'الكل' || this.storeSort ? this.storeGrid() : this.shelves(); }
  setStoreCat(c) { this.storeCat = c; this.draw(); }
  openDetail(id) { this.book = +id; this.show('book'); }
  /* صفحة الكتاب */
  v_book() {
    const id = this.book, b = BK[id], parts = [...Array(Math.min(b.count, 12))].map((_, i) => i + 1), waiting = parts.filter(p => !this.dl[`${id}:${p}`]);
    const facts = [['المؤلف', b.a], ['عدد الأجزاء', n(b.count)], ['التصنيف', b.cat], ['اللغة', 'العربية'], b.pub ? ['الناشر', b.pub] : null].filter(Boolean);
    return `<div class="scroll"><header class="bhead"><img class="bg" src="${A['c' + id]}" alt=""><div class="nav"><button class="hbtn" data-a="setTab" data-p="store" aria-label="رجوع">${ic('back')}</button><button class="hbtn" aria-label="مشاركة">${ic('share')}</button></div>${cov(id)}<h2>${b.t}</h2><p>${b.as}</p></header>
      <div class="panel bbody"><div class="wrap" style="max-width:640px">${b.count > 1 || waiting.length ? `<button class="cta" data-a="dlAll" ${waiting.length ? '' : 'disabled'}>${ic('dl')}${waiting.length ? (b.count > 1 ? `تحميل كل الأجزاء (${n(waiting.length)})` : 'تحميل') : 'كل الأجزاء محمّلة أو قيد التحميل'}</button>` : ''}
      <div class="sect"><h3>${b.count > 1 ? 'الأجزاء' : 'الكتاب'}</h3></div>${parts.map(p => this.partRow(id, p)).join('')}
      <div class="sect"><h3>ما يدعمه هذا الكتاب</h3></div><div class="tags">${DATA.features.map(f => `<span>${f}</span>`).join('')}</div>
      <div class="sect"><h3>عن الكتاب</h3></div><div class="facts">${facts.map(([k, v]) => `<div class="fact"><small>${k}</small>${v}</div>`).join('')}</div></div></div></div>`;
  }
  partRow(id, p) {
    const k = `${id}:${p}`, d = this.dl[k], size = sizeOf(id, p), multi = BK[id].count > 1;
    const sub = !d || d.st === 'done' ? `${n(pagesOf(id, p))} صفحة · ${n(size)} م.ب` : d.st === 'wait' ? 'في الانتظار' : `${n((size * d.p / 100).toFixed(1))} من ${n(size)} م.ب`;
    const btn = !d ? `<button class="mini" data-a="dlOne" data-p="${k}">تحميل</button>` : d.st === 'done' ? `<button class="mini pri" data-a="openPart" data-p="${id}">فتح</button>` : d.st === 'run' ? `<button class="mini" data-a="dlStop" data-p="${k}">إيقاف</button>` : d.st === 'stop' ? `<button class="mini" data-a="dlOne" data-p="${k}">إعادة</button>` : `<button class="mini wait">في الانتظار</button>`;
    return `<div class="prt" data-k="${k}"><i class="n" style="font-style:normal">${n(p)}</i><span><b>${multi ? `الجزء ${n(p)}` : 'الكتاب'}</b><small>${sub}</small>${d && d.st !== 'done' ? `<div class="pr"><i style="width:${d.p}%"></i></div>` : ''}</span>${btn}</div>`;
  }
  openPart(id) { this.openBook(id); }
  refreshPart(k) { const el = this.host.querySelector(`.prt[data-k="${k}"]`), [id, p] = k.split(':').map(Number); if (el) el.outerHTML = this.partRow(id, p); }
  dlOne(k) { this.dl[k] = { st: 'wait', p: this.dl[k]?.p || 0 }; this.queue.push(k); this.pump(); this.draw(); }
  dlAll() { const id = this.book; for (let p = 1; p <= Math.min(BK[id].count, 12); p++) { const k = `${id}:${p}`; if (!this.dl[k]) { this.dl[k] = { st: 'wait', p: 0 }; this.queue.push(k); } } this.pump(); this.draw(); }
  dlStop(k) { this.dl[k].st = 'stop'; this.refreshPart(k); }
  pump() {
    if (this.timer) return;
    this.timer = setInterval(() => {
      const k = this.queue[0]; if (!k) { clearInterval(this.timer); this.timer = null; return; }
      const d = this.dl[k]; if (d.st === 'stop') { this.queue.shift(); return; }
      d.st = 'run'; d.p = Math.min(100, d.p + 7);
      if (d.p >= 100) { d.st = 'done'; this.queue.shift(); const id = +k.split(':')[0]; if (!this.owned(id)) this.lib.unshift({ id, part: BK[id].count > 1 ? +k.split(':')[1] : undefined, pg: 1, of: pagesOf(id, 1) }); if (this.view === 'book') this.draw(); return; }
      if (this.view === 'book') this.refreshPart(k);
    }, 120);
  }
  /* اللوحات */
  s_recent() {
    return `<h3>آخر ١٠ كتب فتحتها</h3><div class="card">${this.hist.slice(0, 10).map(e => `<button class="rb" data-a="openBook" data-p="${e.id}">${cov(e.id)}<span><b>${this.title(e)}</b><small>وصلت إلى صفحة ${n(e.pg)} من ${n(e.of)}</small><i class="pr"><u style="width:${Math.max(3, Math.round(e.pg / e.of * 100))}%"></u></i></span><em>${n(Math.round(e.pg / e.of * 100))}٪</em></button>`).join('')}</div>`;
  }
  s_new() { return `<h3>ورقة جديدة</h3><div class="tgrid">${TPLS.map(([id, s]) => `<button class="tcard" data-a="newPaper" data-p="${id}"><div class="pv">${paperSVG(id)}</div>${s}</button>`).join('')}</div><div class="card"><button class="row">${ic('file')}<span>إضافة كتاب<small>ملف PDF أو ملف نوتس من جهازك</small></span></button></div>`; }
  s_menu() {
    const d = this.doc, c = d.pages.filter((_, i) => this.list(this.key(i)).length).length, m = d.pages.filter(p => this.bms.has(p.no ?? 1)).length;
    return `<div class="card"><button class="row" data-a="sheet" data-p="export">${ic('share')}<span>تصدير ومشاركة</span></button><button class="row" data-a="openPages" data-p="ink">${ic('inked')}<span>المكتوب عليها<small>${n(c)} صفحة</small></span></button><button class="row" data-a="openPages" data-p="marks">${ic('bm')}<span>العلامات<small>${n(m)} صفحة</small></span></button><button class="row" data-a="openPages" data-p="all">${ic('grid')}<span>كل الصفحات</span></button><button class="row" data-a="sheet" data-p="toolset">${ic('gear')}<span>إعدادات الأدوات</span></button></div>`;
  }
  s_export() {
    const c = this.doc.pages.reduce((s, _, i) => s + (this.list(this.key(i)).length ? 1 : 0), 0);
    const r = (i, t, d, a, p) => `<button class="row" data-a="${a}" data-p="${p}">${ic(i)}<span>${t}${d ? `<small>${d}</small>` : ''}</span></button>`;
    return `<h3>تصدير ومشاركة</h3><div class="card">${r('photo', 'صورة هذه الصفحة إلى المعرض', 'تُحفظ مباشرة في معرض الصور مع كتابتك', 'exportRun', 'img1')}${r('grid', 'صور الصفحات المكتوب عليها إلى المعرض', `${n(c)} صفحة`, 'exportRun', 'imgs')}${r('pdf', 'PDF: الصفحات المكتوب عليها', `${n(c)} صفحة مع كتابتك`, 'exportRun', 'pdfs')}${r('lib', 'PDF: الكتاب كاملاً مع كتابتك', '', 'exportRun', 'pdf')}${r('box', 'ملف نوتس (.nots)', 'الكتاب وكتابتك والعلامات: يُفتح في نوتس على أي جهاز', 'exportRun', 'nots')}</div>`;
  }
  exportRun(k) {
    this.closeSheet(); const gallery = k === 'img1' || k === 'imgs'; let v = 0;
    const h = document.createElement('div'); h.className = 'hud glass'; h.innerHTML = '<span>جارٍ التحضير…</span><div class="bar"><i style="width:0"></i></div>'; this.el.append(h);
    const t = setInterval(() => {
      v += 9; h.querySelector('i').style.width = v + '%';
      if (v >= 100) { clearInterval(t); h.remove(); if (gallery) this.toast(k === 'img1' ? 'حُفظت الصورة في المعرض (ألبوم نوتس).' : 'تم الحفظ في المعرض (ألبوم نوتس).'); else this.sheet('saveTo'); }
    }, 70);
  }
  s_saveTo() { return `<h3>الملف جاهز</h3><div class="card"><button class="row" data-a="savedOk">${ic('save')}<span>حفظ في الجهاز<small>اختر المجلد، ويبقى الاسم والامتداد كما هما</small></span></button><button class="row" data-a="savedOk">${ic('share')}<span>مشاركة</span></button></div>`; }
  savedOk() { this.closeSheet(); this.toast('تم الحفظ.'); }
  s_find() { return `<h3>بحث في الكتاب</h3><div class="goto"><input value="ماء المطر" aria-label="بحث"></div><div class="card">${HITS.map(([p, s]) => `<button class="res" data-a="goPage" data-p="0"><b>صفحة ${n(p)}</b><span>${s}</span></button>`).join('')}</div>`; }
  s_toc() { return `<h3>الفهرس</h3><div class="toc">${TOC.map(([l, s, on]) => `<button class="l${l} ${on ? 'on' : ''}" data-a="closeSheet">${s}</button>`).join('')}</div>`; }
  s_pages() {
    const d = this.doc, tab = this.pagesTab, nums = d.pages.map((p, i) => [p, i]);
    const f = tab === 'marks' ? nums.filter(([p]) => this.bms.has(p.no ?? 1)) : tab === 'ink' ? nums.filter(([, i]) => this.list(this.key(i)).length) : nums;
    const title = { all: 'الصفحات', marks: 'العلامات', ink: 'المكتوب عليها' }[tab];
    const body = f.length ? `<div class="thumbs">${f.map(([p, i]) => `<button class="${i === this.cur ? 'on' : ''}" data-a="goPage" data-p="${i}"><div class="pv">${p.img ? `<img src="${A[p.img]}" alt="">` : paperSVG(p.tpl, p.ink)}</div>${n(p.no ?? i + 1)}</button>`).join('')}</div>` : `<p class="t" style="margin:0">${tab === 'marks' ? 'لا توجد علامات بعد.' : 'لا توجد صفحات مكتوب عليها بعد.'}</p>`;
    return `<h3>${title}</h3>${tab === 'all' && d.of ? `<div class="goto"><input inputmode="numeric" placeholder="الانتقال إلى صفحة (١ – ${n(d.of)})" aria-label="رقم الصفحة"><button class="mini pri" data-a="jump" style="height:44px">انتقال</button></div>` : ''}${body}`;
  }
  s_input(o) {
    const title = o.title || (o.kind === 'text' ? 'نص جديد' : 'ملاحظة جديدة');
    return `<h3>${title}</h3><textarea class="ta" placeholder="اكتب هنا"></textarea><div class="btns"><button class="mini" data-a="closeSheet">إلغاء</button><button class="mini pri" data-a="saveInput">حفظ</button></div>`;
  }
  saveInput() {
    const o = this.sp, v = this.ov.querySelector('.ta').value.trim(); this.closeSheet(); if (!v) return;
    const l = this.list(this.key());
    l.push(o.kind === 'text' ? { k: 'text', c: this.col.pen, s: v, x: o.x, y: o.y, z: 34 } : { k: 'pin', x: o.x, y: o.y, s: v, c: this.col.pen });
    this.redrawAll();
  }
  sheetPin(j) { const s = this.list(this.key())[j]; return `<h3>ملاحظة</h3><p style="margin:0 0 4px;line-height:1.9">${esc(s.s)}</p><div class="btns"><button class="mini" data-a="delPin" data-p="${j}" style="color:#B3322A">حذف</button><button class="mini" data-a="closeSheet">تعديل</button><button class="mini pri" data-a="closeSheet">إغلاق</button></div>`; }
  delPin(j) { this.list(this.key()).splice(+j, 1); this.closeSheet(); this.redrawAll(); }
  s_libSort() { return this.sortSheet(SORTS.lib, this.libSort, 'libSortSet'); }
  s_storeSort() { return this.sortSheet(SORTS.store, this.storeSort, 'storeSortSet'); }
  sortSheet(l, cur, a) { return `<h3>الترتيب</h3><div class="card">${l.map((s, i) => `<button class="row" data-a="${a}" data-p="${i}"><span>${s}</span>${i === cur ? `<i class="chk">${ic('check')}</i>` : ''}</button>`).join('')}</div>`; }
  libSortSet(i) { this.libSort = +i; this.closeSheet(); this.draw(); }
  storeSortSet(i) { this.storeSort = +i; this.closeSheet(); this.draw(); }
  s_bookAct(id) {
    const e = this.lib.find(b => b.id === +id);
    return `<h3>${this.title(e)}</h3><div class="card"><button class="row" data-a="sheet" data-p="rename:${id}">${ic('edit')}<span>إعادة التسمية</span></button><button class="row dng" data-a="sheet" data-p="remove:${id}">${ic('trash')}<span>إزالة من المكتبة</span></button></div>`;
  }
  s_rename(id) { const e = this.lib.find(b => b.id === +id); return `<h3>اسم الكتاب</h3><div class="goto"><input value="${esc(this.title(e))}" aria-label="اسم الكتاب"></div><div class="btns"><button class="mini" data-a="closeSheet">إلغاء</button><button class="mini pri" data-a="closeSheet">حفظ</button></div>`; }
  s_remove(id) { const e = this.lib.find(b => b.id === +id); return `<h3>إزالة «${this.title(e)}»</h3><p class="t">يمكن إزالة الملف من هذا الجهاز فقط، ويبقى الكتاب وكتابتك في حسابك. أو حذفه من حسابك ومن كل أجهزتك نهائياً.</p><div class="card"><button class="row" data-a="rmDevice" data-p="${id}">${ic('cloud')}<span>من هذا الجهاز</span></button><button class="row dng" data-a="rmAll" data-p="${id}">${ic('trash')}<span>حذف من كل مكان</span></button></div>`; }
  rmDevice(id) { this.lib.find(b => b.id === +id).cloud = 1; this.closeSheet(); this.draw(); }
  rmAll(id) { this.lib = this.lib.filter(b => b.id !== +id); this.closeSheet(); this.draw(); }
  s_account() {
    return `<div class="acc"><i class="av" style="font-style:normal">ط</i><span><b>طالب العلم</b><small dir="ltr" style="text-align:right">name@gmail.com</small></span></div>
      <div class="card" style="margin-top:12px"><button class="row" data-a="syncNow">${ic('cloud')}<span>زامن الآن<small>آخر مزامنة ${this.synced}</small></span></button><div class="quota"><div><span>Google Drive</span><span style="color:var(--muted)">مستعمل ٣٤٠ م.ب</span></div><i><u></u></i></div></div>
      <div class="card"><button class="row" data-a="flip" data-p="fingerDraws">${ic('touch')}<span>الإصبع يرسم<small>أطفئه ليكتب القلم وحده</small></span><i class="tog ${this.fingerDraws ? 'on' : ''}"></i></button><button class="row" data-a="flip" data-p="awake">${ic('sun')}<span>تبقى الشاشة مضاءة أثناء الدرس</span><i class="tog ${this.awake ? 'on' : ''}"></i></button></div>
      <div class="card"><button class="row">${ic('swap')}<span>نقل كل شيء إلى حساب آخر</span></button><button class="row dng">${ic('out')}<span>تسجيل الخروج</span></button></div>
      <div class="about"><img src="${A['alhikmeh-white-logo']}" alt="مؤسسة الحكمة للثقافة الإسلامية"><span>${RIGHTS}</span></div>`;
  }
  syncNow() { this.toast('جارٍ المزامنة…'); setTimeout(() => { this.synced = '٩:٤١'; this.resheet(); this.toast('تمت المزامنة.'); }, 900); }
  /* فتح خطوة من العرض */
  open(id) {
    this.closeSheet(); this.quiet = false; this.pop = false; this.sel = null; this.conflict = false; this.ruler = null;
    if (id === 'masdar') return this.show('masdar');
    if (id === 'lib' || id === 'store' || id === 'notes') return this.setTab(id);
    if (id === 'book') { this.book = 435; return this.show('book'); }
    if (id === 'new') { this.setTab('notes'); return this.sheet('new'); }
    if (id === 'account') { this.setTab('lib'); return this.sheet('account'); }
    this.tool = 'pen'; if (id === 'conflict') this.conflict = true;
    this.openDoc('masdar');
    if (id === 'quiet') { this.quiet = true; this.applyQuiet(); }
    if (id === 'tools') { this.pop = 'tray'; this.tools(); }
    if (id === 'recent') this.sheet('recent');
    if (id === 'more') { this.pop = 'more'; this.tools(); }
    if (id === 'export') this.sheet('export');
    if (id === 'pages') this.openPages('all');
    if (id === 'menu') this.sheet('menu');
    if (id === 'toolset') this.sheet('toolset');
    if (id === 'toc') this.sheet('toc');
  }
}
App.prototype.sheet = (f => function (k, p) {
  const [a, b] = String(k).split(':');
  if (a === 'pin') { this.pop = false; this.sk = k; this.ov.innerHTML = `<div class="scrim" data-a="closeSheet"></div><div class="sheet" role="dialog"><div class="grab"></div>${this.sheetPin(+b)}</div>`; return; }
  return f.call(this, a, b ?? p);
})(App.prototype.sheet);

/* صفحة العرض */
const STEPS = [
  ['masdar', 'في المصدر', 'تقرأ في المصدر كالمعتاد. الجديد زر واحد: <b>اكتب على هذه الصفحة</b>.'],
  ['write', 'الصفحة', 'الصفحة بعرض الشاشة كاملاً بلا حواف، والأزرار أيقونات فقط. <b>جرّب الكتابة بالفأرة أو بإصبعك،</b> وعجلة الفأرة أو أداة اليد تحرّك الصفحة.'],
  ['quiet', 'صفاء الكتابة', 'عند بدء الكتابة يختفي كل شيء وتبقى الورقة وزر صغير. نقرة على الورقة تعيد الأدوات.'],
  ['tools', 'اللون', 'لا يوجد زر لون: عند اختيار أي أداة تظهر ألوانها مباشرة فتحدد ما تريد.'],
  ['more', 'مربع الأدوات', 'بقية الأدوات تعمل من داخل المربع، ومنها الليزر وإضافة الصور.'],
  ['toolset', 'إعدادات الأدوات', '<b>اسحب الأداة</b> بين الشريط والمربع أو اضغطها لنقلها. إذا قلّت أدوات الشريط قصر معها.'],
  ['toc', 'الفهرس', 'زر الفهرس يفتح الفهرس وحده.'],
  ['menu', 'النقاط الثلاث', 'التصدير، والمكتوب عليها، والعلامات، وكل الصفحات.'],
  ['pages', 'رقم الصفحة', 'رقم الصفحة في الأسفل يفتح الانتقال إلى صفحة.'],
  ['recent', 'آخر ١٠ كتب', 'زر بجانب الحساب يعرض آخر عشرة كتب فتحتها وأين وصلت في كل منها.'],
  ['export', 'التصدير', 'خيارات التصدير الخمسة، ثم الحفظ في الجهاز أو المشاركة.'],
  ['lib', 'كتبي', 'أزرار التصنيف نفسها التي في الكتب، ثم كتبك مع البحث والترتيب. وزر آخر ١٠ كتب بجانب الحساب.'],
  ['store', 'الكتب', 'كل الكتب للتحميل: تصنيفات، وبحث، وترتيب، ورفوف حسب المرجع.'],
  ['book', 'صفحة الكتاب', 'تحميل الأجزاء مع التقدم والإيقاف والإعادة. جرّب زر التحميل.'],
  ['notes', 'ملاحظاتي', 'أوراقك الخاصة خارج الكتب.'],
  ['new', 'ورقة جديدة', 'النجمة تفتح ورقة بيضاء أو قالباً، أو تضيف كتاباً من جهازك.'],
  ['conflict', 'تعارض جهازين', 'إذا كُتب على الصفحة من جهازين، تختار ما تبقيه. لا يضيع شيء.'],
  ['account', 'الحساب', 'المزامنة مع Google Drive، والمساحة، ونقل الحساب، وحقوق مؤسسة الحكمة.'],
];
const DEVICES = {
  ios: { name: 'آيفون', cls: 'ios-ph', plat: 'ios', form: 'phone', w: 393, h: 852, pad: 11, deco: 'island' },
  android: { name: 'أندرويد', cls: 'and-ph', plat: 'android', form: 'phone', w: 412, h: 892, pad: 9, deco: 'punch' },
  ipad: { name: 'آيباد', cls: 'ios-tb', plat: 'ios', form: 'tablet', w: 1194, h: 834, pad: 18 },
  atab: { name: 'تابلت أندرويد', cls: 'and-tb', plat: 'android', form: 'tablet', w: 1280, h: 800, pad: 20 },
};
const qs = new URLSearchParams(location.search);
const S = { dev: qs.get('d') || 'ios', step: qs.get('s') || 'masdar', port: false, apps: [] };
let opening = true;
const $ = q => document.querySelector(q);
const stepsHTML = () => STEPS.map(([id, t], i) => `<button data-st="${id}">${n(i + 1)}&ensp;${t}</button>`).join('');

function buildDevice(key, port, host) {
  const d = DEVICES[key], w = port ? d.h : d.w, h = port ? d.w : d.h;
  const wrap = document.createElement('div'); wrap.className = 'devwrap';
  wrap.innerHTML = `<div class="scaler"><div class="dev ${d.cls}"><div class="screen" style="width:${w}px;height:${h}px">${d.deco ? `<div class="${d.deco}"></div>` : ''}<div class="mount"></div></div></div></div>`;
  host.append(wrap);
  const m = wrap.querySelector('.mount');
  if (d.form === 'tablet' && port) m.classList.add('port');
  const a = new App(m, { plat: d.plat, form: d.form, onStep: id => { if (!opening && S.apps.length === 1) { S.step = id; shellUI(); } } });
  a.dims = { w: w + d.pad * 2, h: h + d.pad * 2 }; a.wrap = wrap;
  return a;
}
function layout() {
  const st = $('.stage'); if (!st) return;
  const availW = st.clientWidth - 40, availH = Math.max(innerHeight - $('.top').offsetHeight - $('.steps').offsetHeight - 92, 420), list = S.apps;
  const sumW = list.reduce((s, a) => s + a.dims.w, 0) + 26 * (list.length - 1), maxH = Math.max(...list.map(a => a.dims.h));
  const k = Math.min(1, availW / sumW, availH / maxH);
  list.forEach(a => {
    const sc = a.wrap.querySelector('.scaler');
    sc.style.width = a.dims.w * k + 'px'; sc.style.height = a.dims.h * k + 'px';
    a.wrap.querySelector('.dev').style.transform = `scale(${k})`;
  });
  $('.devices').classList.toggle('all', list.length > 1);
}
function shellUI() {
  document.querySelectorAll('[data-dev]').forEach(b => b.classList.toggle('on', b.dataset.dev === S.dev));
  document.querySelectorAll('[data-st]').forEach(b => b.classList.toggle('on', b.dataset.st === S.step));
  if ($('.cap')) $('.cap').innerHTML = STEPS.find(x => x[0] === S.step)[2];
  if ($('#rot')) $('#rot').style.display = DEVICES[S.dev]?.form === 'tablet' ? '' : 'none';
}
function rebuild() {
  const box = $('.devices'); box.innerHTML = ''; S.apps = []; opening = true;
  for (const k of S.dev === 'all' ? ['ios', 'android', 'ipad', 'atab'] : [S.dev]) {
    const a = buildDevice(k, S.dev === 'all' ? DEVICES[k].form === 'tablet' : S.port, box);
    if (S.dev === 'all') a.wrap.insertAdjacentHTML('beforeend', `<span>${DEVICES[k].name}</span>`);
    S.apps.push(a); a.open(S.step);
  }
  opening = false; layout(); shellUI();
}
function startShow() {
  document.body.innerHTML = `<div class="show"><header class="top">${logo(42)}<h1>نوتس: قلم المصدر</h1><div class="seg">${Object.entries(DEVICES).map(([k, d]) => `<button data-dev="${k}">${d.name}</button>`).join('')}<button data-dev="all">الكل</button></div><button class="icb" id="rot" title="تدوير" aria-label="تدوير">${ic('undo')}</button></header>
    <nav class="steps">${stepsHTML()}</nav><section class="stage"><div class="devices"></div><p class="cap"></p></section></div>`;
  rebuild();
  document.addEventListener('click', e => {
    const d = e.target.closest('[data-dev]'), s = e.target.closest('[data-st]');
    if (d) { S.dev = d.dataset.dev; S.port = false; rebuild(); }
    if (s) { S.step = s.dataset.st; opening = true; S.apps.forEach(a => a.open(S.step)); opening = false; shellUI(); }
    if (e.target.closest('#rot')) { S.port = !S.port; rebuild(); }
  });
  addEventListener('resize', layout);
}
function startSolo() {
  document.body.classList.add('solo');
  const tablet = Math.min(innerWidth, innerHeight) >= 600, ios = /iPhone|iPad|iPod/.test(navigator.userAgent);
  document.body.innerHTML = `<div class="solo-app"><div></div></div><button class="solo-tab" aria-label="الخطوات">${ic('grid')}</button><div class="solo-panel"><div class="hd"><h2>خطوات التصميم</h2><button class="icb" id="cl" aria-label="إغلاق">${ic('close')}</button></div><nav class="steps">${stepsHTML()}</nav></div>`;
  const m = $('.solo-app').firstChild;
  if (tablet && innerHeight > innerWidth) m.classList.add('port');
  const app = new App(m, { plat: ios ? 'ios' : 'android', form: tablet ? 'tablet' : 'phone', solo: true });
  app.open(location.hash.slice(1) || 'masdar');
  document.addEventListener('click', e => {
    const pn = $('.solo-panel'), s = e.target.closest('[data-st]');
    if (e.target.closest('.solo-tab')) pn.classList.add('on');
    if (e.target.closest('#cl')) pn.classList.remove('on');
    if (s) { pn.classList.remove('on'); app.open(s.dataset.st); }
  });
}
const q = new URLSearchParams(location.search).get('v');
const small = Math.min(innerWidth, innerHeight) < 760 || (matchMedia('(pointer:coarse)').matches && innerWidth < 1100);
Promise.all([document.fonts.load("36px 'Aref Ruqaa'"), document.fonts.load("700 16px 'Muna'"), document.fonts.load("900 16px 'Muna'"), document.fonts.load("16px 'Muna'")]).finally(() => { (q === 'solo' || (small && q !== 'show')) ? startSolo() : startShow(); });
