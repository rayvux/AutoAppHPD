# Third-party notices

## VasDolly 3.0.6

`VasDolly.jar` is the Tencent VasDolly command-line channel packaging tool.

- Upstream: https://github.com/Tencent/VasDolly
- The original license distributed inside this JAR is reproduced in `licenses/VasDolly-LICENSE.txt`.
- The JAR is included unchanged. AutoAppHPD invokes it using the locally installed Java runtime.

## External tools and services

Android SDK Build Tools (`apksigner`, `zipalign`, `aapt`) and Java are resolved from the user's environment and are not bundled here.
Baidu and Bangcle are external services. Users supply their own credentials, APKs and service accounts at runtime.
No vendor login passwords, API keys, personal signing keys, or service sessions are part of this repository or its installers.
