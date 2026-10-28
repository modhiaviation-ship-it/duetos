// DuetOS Firefox defaults (you can still change any of these in about:config).

// Hardware video decode via VA-API; no AV1 (no hardware decoder on Gemini Lake),
// so YouTube falls back to VP9/H.264, which the GPU decodes.
pref("media.ffmpeg.vaapi.enabled", true);
pref("media.hardware-video-decoding.enabled", true);
pref("media.av1.enabled", false);

// Memory: fewer content processes, unload background tabs when RAM gets low.
pref("dom.ipc.processCount", 4);
pref("browser.tabs.unloadOnLowMemory", true);
pref("browser.low_commit_space_threshold_percent", 25);

// Fewer eMMC writes: save the session every 60 s instead of 15 s.
pref("browser.sessionstore.interval", 60000);

// Touch: touch density UI, smooth kinetic scrolling, pinch zoom.
pref("browser.uidensity", 2);
pref("apz.allow_zooming", true);
pref("general.smoothScroll.msdPhysics.enabled", true);
pref("widget.gtk.overlay-scrollbars.enabled", true);

// Dark theme for UI and websites that support it.
pref("layout.css.prefers-color-scheme.content-override", 0);
pref("extensions.activeThemeID", "firefox-compact-dark@mozilla.org");

// Background work and telemetry off.
pref("datareporting.healthreport.uploadEnabled", false);
pref("datareporting.policy.dataSubmissionEnabled", false);
pref("toolkit.telemetry.enabled", false);
pref("app.shield.optoutstudies.enabled", false);
pref("extensions.pocket.enabled", false);
pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);
pref("browser.newtabpage.activity-stream.showSponsored", false);
pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
