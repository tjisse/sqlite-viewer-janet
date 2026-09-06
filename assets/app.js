document.addEventListener('change', event => {
  if (event.target.matches('[data-autosubmit]')) event.target.form.requestSubmit();
});
document.addEventListener('submit', event => {
  const form = event.target;
  const hidden = form.querySelector('[name="hidden"]');
  if (hidden) hidden.value = [...form.querySelectorAll('[data-column]:not(:checked)')].map(el => el.dataset.column).join(',');
});
document.addEventListener('keydown', event => {
  if ((event.ctrlKey || event.metaKey) && event.key === 'Enter' && event.target.id === 'sql') {
    event.preventDefault(); event.target.form.requestSubmit();
  }
});
let lastUpdate = Date.now();
new MutationObserver(() => { lastUpdate = Date.now(); }).observe(document.body, {childList:true, subtree:true, attributes:true, attributeFilter:['data-heartbeat']});
setInterval(() => {
  const live = document.getElementById('live');
  if (live && live.dataset.heartbeat && !live.classList.contains('expired') && Date.now() - lastUpdate > 22000) {
    live.textContent = '● Reconnecting';
    lastUpdate = Date.now();
  }
}, 5000);
