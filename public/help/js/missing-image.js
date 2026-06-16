/* Gracefully handle help-site images that the Internet Archive never captured.
   These guides were recreated from web.archive.org snapshots (2012/2015); 57 of
   the original screenshot/icon images were never archived and are unrecoverable.
   Rather than show broken-image boxes, replace each failed image with a small
   inline note so the surrounding text still reads cleanly. */
(function () {
  function handle(img) {
    if (img.getAttribute('data-missing-handled')) return;
    img.setAttribute('data-missing-handled', '1');
    var name = (img.getAttribute('src') || '').split('/').pop();
    try { name = decodeURIComponent(name); } catch (e) {}
    var span = document.createElement('span');
    span.className = 'missing-image';
    span.title = 'This screenshot was not preserved in the Internet Archive.';
    span.textContent = 'image not archived: ' + name;
    if (img.parentNode) img.parentNode.replaceChild(span, img);
  }
  function wire() {
    var imgs = document.querySelectorAll('img[src*="/help/images/"]');
    for (var i = 0; i < imgs.length; i++) {
      var img = imgs[i];
      if (img.complete && img.naturalWidth === 0) handle(img);
      else img.addEventListener('error', (function (el) { return function () { handle(el); }; })(img));
    }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', wire);
  else wire();
})();
