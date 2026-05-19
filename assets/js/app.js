// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let Hooks = {}

function applyTheme(t) {
  let dark =
    t === "dark" ||
    (t === "system" &&
      window.matchMedia &&
      window.matchMedia("(prefers-color-scheme: dark)").matches)
  document.documentElement.classList.toggle("dark", !!dark)
}

Hooks.ThemeToggle = {
  mounted() {
    let stored = (() => {
      try { return localStorage.getItem("tf:theme") } catch (_) { return null }
    })()
    let current = stored || "system"
    this.pushEvent("theme:current", {theme: current})

    this.handleEvent("theme:set", ({theme}) => {
      try { localStorage.setItem("tf:theme", theme) } catch (_) {}
      applyTheme(theme)
    })

    // Re-evaluate when system preference changes (only matters for :system).
    if (window.matchMedia) {
      let mql = window.matchMedia("(prefers-color-scheme: dark)")
      this._mqlListener = () => {
        let t = (() => { try { return localStorage.getItem("tf:theme") } catch (_) { return "system" } })() || "system"
        if (t === "system") applyTheme("system")
      }
      mql.addEventListener ? mql.addEventListener("change", this._mqlListener) : mql.addListener(this._mqlListener)
      this._mql = mql
    }
  },
  destroyed() {
    if (this._mql && this._mqlListener) {
      this._mql.removeEventListener ? this._mql.removeEventListener("change", this._mqlListener) : this._mql.removeListener(this._mqlListener)
    }
  }
}

function applyDensity(d) {
  let html = document.documentElement
  html.classList.remove("density-compact", "density-fluid")
  if (d === "compact") html.classList.add("density-compact")
  if (d === "fluid") html.classList.add("density-fluid")
}

Hooks.DensityToggle = {
  mounted() {
    let stored = (() => {
      try { return localStorage.getItem("tf:density") } catch (_) { return null }
    })()
    let current = stored || "standard"
    this.pushEvent("density:current", {density: current})

    this.handleEvent("density:set", ({density}) => {
      try { localStorage.setItem("tf:density", density) } catch (_) {}
      applyDensity(density)
    })
  }
}

Hooks.FileDownload = {
  mounted() {
    this.handleEvent("download:file", ({filename, content, mime}) => {
      let type = mime || "application/octet-stream"
      let blob = new Blob([content], {type})
      let url = URL.createObjectURL(blob)
      let a = document.createElement("a")
      a.href = url
      a.download = filename || "download"
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      // Revoke after a short delay so Safari has time to start the download.
      setTimeout(() => URL.revokeObjectURL(url), 1500)
    })
  }
}

Hooks.FileImport = {
  mounted() {
    this.el.addEventListener("change", (e) => {
      let file = e.target.files && e.target.files[0]
      if (!file) return
      let reader = new FileReader()
      reader.onload = () => {
        this.pushEvent("import:file", {
          filename: file.name,
          content: reader.result
        })
        // Reset so the same file can be selected again later.
        e.target.value = ""
      }
      reader.onerror = () => {
        this.pushEvent("import:error", {message: "No se pudo leer el archivo."})
        e.target.value = ""
      }
      reader.readAsText(file)
    })
  }
}

Hooks.ClipboardCopy = {
  mounted() {
    this.handleEvent("clipboard:copy", ({text}) => {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text)
      } else {
        const ta = document.createElement("textarea")
        ta.value = text
        ta.style.position = "fixed"
        ta.style.opacity = "0"
        document.body.appendChild(ta)
        ta.select()
        try { document.execCommand("copy") } catch (_) {}
        document.body.removeChild(ta)
      }
    })
  }
}

let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  hooks: Hooks,
  params: {_csrf_token: csrfToken}
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

