# The statistics service (nots/api/ on alhikmeh.org)

- `collect.php` takes the app's reports (gzip JSON, header `X-Nots-Key`),
  only ever sent over Wi-Fi. Each report is the whole picture of one device
  and replaces the one before; reading per day goes to `daily`, addresses to
  `ips`, messages («اقترح كتاباً», «الإبلاغ عن مشكلة») to `messages`.
- `admin.php` answers the app's admin panel. The request carries the Drive
  access token of the account signed in on the app; the server asks Google
  (`drive/v3/about`) whose it is, and answers only the owner
  (`OWNER` in lib.php) and the administrators the owner added.
- `data/` holds `stats.sqlite` (made on first use) and `geo.sqlite`, closed
  to the web by its own `.htaccess` and by the root one (which denies
  `.sqlite`).

The country of an address comes from `geo.sqlite`, built from the free
DB-IP Lite country CSV (CC BY 4.0, <https://db-ip.com>), on the server
itself: no address is sent anywhere else. To refresh it monthly:

```
curl -LO https://download.db-ip.com/free/dbip-country-lite-YYYY-MM.csv.gz
python build_geo.py dbip-country-lite-YYYY-MM.csv.gz geo.sqlite
python deploy.py --geo geo.sqlite
```
