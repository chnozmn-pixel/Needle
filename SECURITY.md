# Security Policy / Güvenlik Politikası

**EN** — Needle is a local file search app. It reads your filesystem to build an
index and keeps that index on your Mac. The optional HTTP and ETP endpoints bind
to `127.0.0.1` only and have no authentication, so they must never be exposed to
a network or a untrusted local process.

**TR** — Needle yerel bir dosya arama uygulamasıdır. Dizin oluşturmak için
dosya sisteminizi okur ve bu dizini Mac'inizde tutar. İsteğe bağlı HTTP ve ETP
sunucuları yalnızca `127.0.0.1` adresine bağlanır ve kimlik doğrulaması yoktur;
bu yüzden ağa veya güvenilmeyen yerel süreçlere açılmamalıdırlar.

## Supported versions / Desteklenen sürümler

| Version / Sürüm | Supported / Destekleniyor |
| --- | --- |
| 0.5.x | ✅ |
| < 0.5.0 | ❌ |

## Reporting a vulnerability / Güvenlik açığı bildirme

**EN** — Please do **not** open a public issue for security problems. Use the
**Security → Report a vulnerability** button on the GitHub repository to send a
private advisory. Include the Needle version, macOS version, reproduction steps
and the impact you observed. You should receive an acknowledgement within
7 days; we will keep you informed while the issue is investigated and a fix is
prepared. Please give us a reasonable window to release the fix before public
disclosure.

**TR** — Güvenlik sorunları için lütfen **herkese açık issue açmayın**. GitHub
deposundaki **Güvenlik → Report a vulnerability** düğmesiyle özel bir bildirim
gönderin. Needle sürümünü, macOS sürümünü, yeniden üretme adımlarını ve gözlediğiniz
etkiyi yazın. 7 gün içinde yanıt almalısınız; sorun incelenir ve düzeltme
hazırlanırken sizi bilgilendireceğiz. Herkese açıklamadan önce düzeltmenin
yayınlanması için makul bir süre tanıyın.

## Scope notes / Kapsam notları

- The release ZIP is ad-hoc signed because no Apple Developer ID certificate is
  available. This is a distribution limitation, not a vulnerability; see the
  release notes for the one-time Gatekeeper approval steps.
  / Yayın ZIP'i Apple Developer ID sertifikası olmadığı için ad-hoc imzalıdır.
  Bu bir güvenlik açığı değil, dağıtım kısıtıdır; tek seferlik Gatekeeper onayı
  için sürüm notlarına bakın.
- Issues in third-party dependencies or in macOS/Spotlight itself should be
  reported to their respective vendors.
  / Üçüncü taraf bağımlılıklar veya macOS/Spotlight kaynaklı sorunlar ilgili
  taraflara bildirilmelidir.
