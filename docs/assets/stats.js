(function () {
  var REPO = "gioxx/Syno-TransmissionVPNShield";

  function formatCount(n) {
    if (n >= 1000) {
      return (n / 1000).toFixed(1).replace(/\.0$/, "") + "k";
    }
    return String(n);
  }

  function countUp(el, target, duration) {
    var start = 0;
    var startTime = null;

    function step(timestamp) {
      if (startTime === null) startTime = timestamp;
      var progress = Math.min((timestamp - startTime) / duration, 1);
      var eased = 1 - Math.pow(1 - progress, 3);
      el.textContent = formatCount(Math.round(start + (target - start) * eased));
      if (progress < 1) requestAnimationFrame(step);
    }

    requestAnimationFrame(step);
  }

  function reveal(el) {
    requestAnimationFrame(function () {
      el.classList.add("is-ready");
    });
  }

  function setStatNumber(name, value) {
    var el = document.querySelector('[data-stat="' + name + '"]');
    if (!el) return;
    reveal(el);
    countUp(el, value, 900);
  }

  function setStatText(name, text) {
    var el = document.querySelector('[data-stat="' + name + '"]');
    if (!el) return;
    el.textContent = text;
    reveal(el);
  }

  function fetchJSON(url) {
    return fetch(url).then(function (res) {
      if (!res.ok) throw new Error("request failed");
      return res.json();
    });
  }

  fetchJSON("https://api.github.com/repos/" + REPO)
    .then(function (data) { setStatNumber("stars", data.stargazers_count); })
    .catch(function () { setStatText("stars", "-"); });

  // repos/.../ open_issues_count counts open pull requests too; the search
  // API's issue-only query is the only way to get a PR-free issue count.
  fetchJSON("https://api.github.com/search/issues?q=repo:" + REPO + "+type:issue+state:open")
    .then(function (data) { setStatNumber("open-issues", data.total_count); })
    .catch(function () { setStatText("open-issues", "-"); });

  fetchJSON("https://api.github.com/repos/" + REPO + "/releases/latest")
    .then(function (data) { setStatText("latest-release", data.tag_name); })
    .catch(function () { setStatText("latest-release", "-"); });
})();
