(function () {
  "use strict";

  var REPO = "allen-bot-ctl/EasyLens";
  var API_URL = "https://api.github.com/repos/" + REPO + "/releases/latest";
  var RELEASE_PAGE = "https://github.com/" + REPO + "/releases/latest";

  var versionEl = document.getElementById("release-version");
  var footerVersionEl = document.getElementById("footer-version");
  var statusEl = document.getElementById("release-status");
  var assetsEl = document.getElementById("release-assets");
  var fallbackEl = document.getElementById("release-fallback");
  var downloadEl = document.getElementById("download-latest");

  if (downloadEl) {
    downloadEl.href = RELEASE_PAGE;
  }

  function setFallback(message) {
    if (!fallbackEl) return;
    fallbackEl.textContent = message;
    fallbackEl.hidden = false;
  }

  function setVersion(tag) {
    var version = String(tag || "").trim();
    if (!version) return;
    if (versionEl) versionEl.textContent = version;
    if (footerVersionEl) footerVersionEl.textContent = version;
  }

  function formatDate(value) {
    if (!value) return "";
    var date = new Date(value);
    if (Number.isNaN(date.getTime())) return "";
    return date.toLocaleDateString("zh-CN", {
      year: "numeric",
      month: "short",
      day: "numeric",
    });
  }

  function formatBytes(bytes) {
    var value = Number(bytes);
    if (!Number.isFinite(value) || value <= 0) return "";
    var units = ["B", "KB", "MB", "GB"];
    var index = Math.min(Math.floor(Math.log(value) / Math.log(1024)), units.length - 1);
    var amount = value / Math.pow(1024, index);
    return amount.toFixed(index === 0 ? 0 : 1) + " " + units[index];
  }

  function assetInfo(name) {
    if (/mac.*arm64.*\.(dmg|zip)$/i.test(name)) {
      return { rank: 1, label: "macOS Apple Silicon (arm64)" };
    }
    if (/mac.*(x64|amd64).*\.(dmg|zip)$/i.test(name)) {
      return { rank: 2, label: "macOS Intel (x64)" };
    }
    if (/win.*\.exe$/i.test(name)) {
      return { rank: 0, label: "Windows x64" };
    }
    if (/linux.*\.(appimage|zip|tar\.gz)$/i.test(name) || /\.appimage$/i.test(name)) {
      return { rank: 3, label: "Linux x86_64" };
    }
    if (/\.dmg$/i.test(name)) return { rank: 1, label: "macOS" };
    if (/\.exe$/i.test(name)) return { rank: 0, label: "Windows" };
    if (/\.(appimage|deb|rpm|snap)$/i.test(name)) return { rank: 3, label: "Linux" };
    return { rank: 9, label: "其他" };
  }

  function artifactKindRank(name) {
    if (/\.(dmg|exe|appimage)$/i.test(name)) return 0;
    if (/\.zip$/i.test(name)) return 1;
    return 2;
  }

  function renderAssets(assets) {
    if (!assetsEl) return;
    assetsEl.replaceChildren();

    var visible = assets
      .filter(function (asset) {
        return asset && asset.name && asset.browser_download_url;
      })
      .sort(function (left, right) {
        var leftInfo = assetInfo(left.name);
        var rightInfo = assetInfo(right.name);
        return (
          leftInfo.rank - rightInfo.rank ||
          artifactKindRank(left.name) - artifactKindRank(right.name) ||
          left.name.localeCompare(right.name)
        );
      });

    visible.forEach(function (asset) {
      var info = assetInfo(asset.name);
      var link = document.createElement("a");
      link.className = "asset-link";
      link.href = asset.browser_download_url;
      link.rel = "noreferrer";
      link.title = info.label + " · " + asset.name;
      link.innerHTML =
        '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3v12m0 0 5-5m-5 5-5-5M5 21h14"/></svg>' +
        '<span class="asset-main"><span class="asset-name"></span><span class="asset-platform"></span></span>' +
        '<span class="asset-size"></span>';

      var nameEl = link.querySelector(".asset-name");
      var platformEl = link.querySelector(".asset-platform");
      var sizeEl = link.querySelector(".asset-size");
      if (nameEl) nameEl.textContent = asset.name;
      if (platformEl) platformEl.textContent = info.label;
      if (sizeEl) sizeEl.textContent = formatBytes(asset.size);
      assetsEl.appendChild(link);
    });

    assetsEl.hidden = visible.length === 0;
    return visible.length;
  }

  function showNoRelease() {
    if (statusEl) statusEl.textContent = "尚未发布首个 Release";
    setFallback("即将提供 Linux、Windows x64 与 macOS（Intel / Apple Silicon）安装包，也可从源码构建。按钮仍会打开最新 Release 页面。");
  }

  function showRelease(release) {
    setVersion(release.tag_name);
    if (statusEl) {
      var date = formatDate(release.published_at || release.created_at);
      statusEl.textContent = date ? "发布于 " + date : "已发布";
    }

    var count = renderAssets(Array.isArray(release.assets) ? release.assets : []);
    if (count > 0) {
      if (fallbackEl) fallbackEl.hidden = true;
    } else {
      setFallback("该 Release 暂未附带构建产物。按钮仍会打开 Release 页面，也可以从源码构建。");
    }
  }

  function showUnavailable() {
    if (statusEl) statusEl.textContent = "暂时无法读取发布信息";
    setFallback("无法连接 GitHub API 获取最新版本。下载按钮仍指向最新 Release，也可以从源码构建。");
  }

  function loadLatestRelease() {
    if (!window.fetch || !versionEl) return;

    if (navigator.onLine === false) {
      showUnavailable();
      return;
    }

    var controller = typeof AbortController === "function" ? new AbortController() : null;
    var timeout = controller ? window.setTimeout(function () { controller.abort(); }, 9000) : null;

    fetch(API_URL, {
      headers: { Accept: "application/vnd.github+json" },
      signal: controller ? controller.signal : undefined,
    })
      .then(function (response) {
        if (response.status === 404) {
          showNoRelease();
          return null;
        }
        if (!response.ok) throw new Error("GitHub API responded with " + response.status);
        return response.json();
      })
      .then(function (release) {
        if (release) showRelease(release);
      })
      .catch(function () {
        showUnavailable();
      })
      .finally(function () {
        if (timeout) window.clearTimeout(timeout);
      });
  }

  function attachCopyButtons() {
    var buttons = document.querySelectorAll("[data-copy-target]");
    Array.prototype.forEach.call(buttons, function (button) {
      button.addEventListener("click", function () {
        var target = document.getElementById(button.getAttribute("data-copy-target"));
        if (!target) return;
        var text = target.textContent || "";
        var done = function () {
          var original = button.textContent;
          button.textContent = "已复制";
          window.setTimeout(function () {
            button.textContent = original;
          }, 1600);
        };

        if (navigator.clipboard && window.isSecureContext) {
          navigator.clipboard.writeText(text).then(done, function () {
            button.textContent = "请手动复制";
          });
          return;
        }

        var textarea = document.createElement("textarea");
        textarea.value = text;
        textarea.setAttribute("readonly", "");
        textarea.style.position = "fixed";
        textarea.style.opacity = "0";
        document.body.appendChild(textarea);
        textarea.select();
        try {
          document.execCommand("copy");
          done();
        } catch (error) {
          button.textContent = "请手动复制";
        }
        document.body.removeChild(textarea);
      });
    });
  }

  loadLatestRelease();
  attachCopyButtons();
})();
