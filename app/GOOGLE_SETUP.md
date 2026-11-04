# تفعيل المزامنة مع Google Drive

تعمل المزامنة بعد إنشاء هوية للتطبيق عند Google، وهي خطوة لا تتم إلا من حسابك أنت.
تستغرق نحو 10 دقائق وتُعمل مرة واحدة. بدونها يبقى كل شيء في التطبيق يعمل، وتظهر
شاشة Drive برسالة «غير مهيأ».

الافتتاح من: https://console.cloud.google.com

## 1. المشروع وواجهة Drive

1. أنشئ مشروعاً جديداً، وليكن اسمه `Nots`.
2. من **APIs & Services > Library** فعّل **Google Drive API**.

## 2. شاشة الموافقة

من **Google Auth Platform > Branding** (أو OAuth consent screen):

1. اسم التطبيق `نوتس`، والبريد بريدك. نوع الجمهور **External**.
2. من **Data Access** أضف الصلاحية
   `https://www.googleapis.com/auth/drive.appdata`.
3. من **Audience** اضغط **Publish app**.

الصلاحية `drive.appdata` تخص مجلد التطبيق المخفي فقط، ولا يرى التطبيق بها أي ملف
آخر من ملفات المستخدم.

## 3. ثلاثة معرّفات

من **Clients > Create client**:

| النوع | الإعدادات | الغرض |
|---|---|---|
| **Android** | الحزمة `org.alhikmeh.nots`، وبصمة SHA-1 أدناه | يسمح لتطبيقك باستخدام تسجيل دخول Google |
| **Web application** | بلا إعدادات | معرّفه هو `GOOGLE_WEB_CLIENT_ID` |
| **Desktop app** | بلا إعدادات | معرّفه وكلمته للأجهزة دون خدمات Google |

عميل **Desktop app** وحده يكفي لتعمل المزامنة على كل الأجهزة عبر المتصفح. عميلا
**Web** و**Android** معاً يضيفان نافذة اختيار الحساب المعتادة في الأجهزة التي فيها
خدمات Google.

بصمة SHA-1 لمفتاح التوقيع الحالي (مأخوذة من الـ APK نفسه):

```
55:DB:8A:76:80:F5:25:93:D1:AD:5F:D1:82:10:B6:C5:DE:52:39:DD
```

## 4. إعطاء المعرّفات لبناء التطبيق

في GitHub من **Settings > Secrets and variables > Actions** أضف:

| الاسم | القيمة |
|---|---|
| `GOOGLE_WEB_CLIENT_ID` | Client ID الخاص بـ Web application |
| `GOOGLE_BROWSER_CLIENT_ID` | Client ID الخاص بـ Desktop app |
| `GOOGLE_BROWSER_CLIENT_SECRET` | Client secret الخاص بـ Desktop app |

ثم ابنِ التطبيق. للبناء المحلي مرّر القيم نفسها:

```
flutter build apk --release --dart-define=GOOGLE_WEB_CLIENT_ID=... --dart-define=GOOGLE_BROWSER_CLIENT_ID=... --dart-define=GOOGLE_BROWSER_CLIENT_SECRET=...
```

## كيف يسجّل المستخدم الدخول

- **جهاز فيه خدمات Google**: نافذة اختيار الحساب المعتادة.
- **جهاز بلا خدمات Google** (هواوي مثلاً): تُفتح صفحة Google في تبويب متصفح فوق
  التطبيق، يدخل بياناته ويوافق، ثم يعود التطبيق وحده.

لا يمكن أن تكون الصفحة في WebView عادي داخل التطبيق، لأن Google يرفض ذلك بالخطأ
`disallowed_useragent`. لذلك يُستخدم Custom Tab، فإن لم يوجد متصفح يدعمه يُفتح
المتصفح المثبّت.

إن ظهر الخطأ `canceled` مباشرة بعد اختيار الحساب، فالسبب غالباً بصمة SHA-1 أو اسم
الحزمة في الخطوة 3.
