// Audience measurement with Umami (a.openmae.com), which sets no cookie. It loads only on openmae.com itself: in
// development (localhost, a local address, a container on this Mac) nothing is loaded and nothing is sent. The
// pairing page (/p) never includes this file: its address holds a pairing code after the "#".
(() => {
  "use strict";

  const SITES = ["openmae.com", "www.openmae.com"];
  if (!SITES.includes(location.hostname)) return;

  const script = document.createElement("script");
  script.src = "https://a.openmae.com/script.js";
  script.dataset.websiteId = "6fa8db55-cd0a-4da8-933c-242b61369373";
  script.dataset.domains = SITES.join(","); // Umami's own guard, should this file ever run elsewhere
  script.dataset.excludeHash = "true"; // the anchors (#fonctions…) count as their page
  document.head.append(script);
})();
