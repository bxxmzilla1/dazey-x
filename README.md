# Dazey X

Dazey's camera (with the built-in photo spoofing) behind a required account. Users sign up / sign in
with email + password against a Supabase project; the camera only loads after a successful sign in.

```
.
├── project.yml                       XcodeGen spec (generates DazeyX.xcodeproj)
├── build_ipa.sh                      archive + export → build/DazeyX(-unsigned).ipa
├── .github/workflows/build-ipa.yml   CI: builds an unsigned .ipa on a macOS runner
└── DazeyX/
    ├── DazeyXApp.swift      @main entry point
    ├── SupabaseConfig.swift Supabase project URL + anon/publishable key
    ├── AuthManager.swift    sign in / sign up / reset / refresh, session in Keychain
    ├── AuthView.swift       login gate + sign in / sign up screen
    ├── NativeCamera.swift   camera, photo queue, account menu
    └── SpoofEngine.swift    HEIC clone/swap + proxy-IP GPS
```

## Supabase setup

1. Create a project at [supabase.com](https://supabase.com).
2. **Project Settings → API**: copy the Project URL and the `anon` / publishable key into
   `DazeyX/SupabaseConfig.swift`. Never use the `service_role` / secret key in the app.
3. **Authentication → Sign In / Providers → Email**: keep it enabled. If **Confirm email** is on,
   new users must open the emailed link before they can sign in; turn it off to let them in immediately.
4. **Authentication → Users** lists every account; delete or ban a user there and the app signs
   them out the next time it's opened.

## Build

Push to `main` and download the `DazeyX-unsigned-ipa` artifact from the Actions run, then sign it
with Sideloadly / AltStore. On a Mac: `./build_ipa.sh --unsigned`.
