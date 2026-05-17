defmodule TestFlowPhxWeb.TesterLiveTest do
  use TestFlowPhxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TestFlowPhx.Domain.{Request, Response}
  alias TestFlowPhx.Support.FakeHttpExecutor

  setup do
    FakeHttpExecutor.reset()
    :ok
  end

  describe "mount + initial render" do
    test "GET / shows the shell with method/url bar and subtabs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "TestFlow"
      assert html =~ "Collections"
      assert html =~ "History"
      assert html =~ "Send"
      assert html =~ "Params"
      assert html =~ "Headers"
      assert html =~ "Body"
      assert html =~ "Auth"
    end

    test "sidebar toggles between Collections and History", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert render(view) =~ "Sin colecciones"

      assert view
             |> element("aside button", "History")
             |> render_click() =~ "Sin historial"
    end
  end

  describe "subtab navigation" do
    test "switches request subtab between Params / Headers / Body / Auth", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      headers_html = view |> element("button", "Headers") |> render_click()
      assert headers_html =~ "Header-Name"

      body_html = view |> element("button", "Body") |> render_click()
      assert body_html =~ "JSON"
      assert body_html =~ "Raw"

      auth_html = view |> element("button", "Auth") |> render_click()
      assert auth_html =~ "Bearer"
      assert auth_html =~ "API Key"
    end
  end

  describe "update_request" do
    test "phx-change rebuilds the active request", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> form("#request-form",
        request: %{method: "POST", url: "https://example.test/x"}
      )
      |> render_change()

      assert render(view) =~ "https://example.test/x"
    end
  end

  describe "send → response" do
    test "stages a 200 response and shows the body", %{conn: conn} do
      FakeHttpExecutor.stage(%Response{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body: ~s({"ok":true}),
        body_decoded: %{"ok" => true},
        duration_ms: 5,
        size_bytes: 11
      })

      {:ok, view, _html} = live(conn, "/")

      view
      |> form("#request-form",
        request: %{method: "GET", url: "https://example.test/ping"}
      )
      |> render_submit()

      html = await_response(view)

      assert html =~ ">200<"
      assert html =~ "5 ms"
      assert html =~ ~r/&quot;ok&quot;:\s*true/
    end

    test "shows error panel for network failures", %{conn: conn} do
      FakeHttpExecutor.stage(%Response{
        error: %{type: :timeout, message: "receive_timeout"}
      })

      {:ok, view, _html} = live(conn, "/")

      view
      |> form("#request-form",
        request: %{method: "GET", url: "https://slow.test/"}
      )
      |> render_submit()

      html = await_response(view)

      assert html =~ "timeout"
      assert html =~ "receive_timeout"
    end
  end

  describe "body editors" do
    test "form_urlencoded body subtab renders a kv editor over body_form after Add row", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("button", "Body") |> render_click()

      view
      |> form("#request-form", request: %{body_type: "form_urlencoded"})
      |> render_change()

      html = view |> element(~s|button[phx-click="add_kv_row"][phx-value-field="body_form"]|) |> render_click()

      assert html =~ ~s(name="request[body_form][0][key])
      assert html =~ ~s(name="request[body_form][0][value])
      # The kv_editor for form_urlencoded does NOT emit the type select.
      refute html =~ ~s(name="request[body_form][0][type])
    end

    test "multipart editor adds a row with the type select", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("button", "Body") |> render_click()

      view
      |> form("#request-form", request: %{body_type: "multipart"})
      |> render_change()

      html = view |> element(~s|button[phx-click="add_form_row"]|) |> render_click()

      assert html =~ ~s(name="request[body_form][0][type])
      assert html =~ ~s(<option value="text" selected)
    end

    test "multipart row switches to file_path input when type is file", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("button", "Body") |> render_click()

      view
      |> form("#request-form", request: %{body_type: "multipart"})
      |> render_change()

      view |> element(~s|button[phx-click="add_form_row"]|) |> render_click()

      # Step 1: flip type=file (file_path input doesn't exist yet, only value does)
      html =
        view
        |> form("#request-form",
          request: %{
            body_form: %{"0" => %{"enabled" => "true", "key" => "avatar", "type" => "file"}}
          }
        )
        |> render_change()

      assert html =~ ~s(name="request[body_form][0][file_path])
      refute html =~ ~s(name="request[body_form][0][value])

      # Step 2: now the file_path input exists — fill it
      html2 =
        view
        |> form("#request-form",
          request: %{
            body_form: %{
              "0" => %{
                "enabled" => "true",
                "key" => "avatar",
                "type" => "file",
                "file_path" => "/tmp/a.png"
              }
            }
          }
        )
        |> render_change()

      assert html2 =~ "/tmp/a.png"
    end
  end

  describe "tab bar" do
    test "mount seeds one Untitled tab and shows the new-tab button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Untitled"
      assert html =~ ~s(aria-label="New tab")
      assert html =~ ~s(aria-label="Close tab")
    end

    test "new_tab appends a tab and makes it active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> form("#request-form", request: %{method: "POST", url: "https://a.test/"})
      |> render_change()

      view |> element(~s|button[aria-label="New tab"]|) |> render_click()

      html = render(view)

      assert html =~ "https://a.test/"
      assert tab_count(html) == 2
      url_input_value = url_input(html)
      assert url_input_value == ""
    end

    test "select_tab switches the active tab and restores its request", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> form("#request-form", request: %{method: "POST", url: "https://first.test/"})
      |> render_change()

      first_id = active_tab_id(render(view))

      view |> element(~s|button[aria-label="New tab"]|) |> render_click()

      view
      |> form("#request-form", request: %{method: "GET", url: "https://second.test/"})
      |> render_change()

      second_id = active_tab_id(render(view))
      assert second_id != first_id

      view |> element(~s|button[phx-click="select_tab"][phx-value-id="#{first_id}"]|) |> render_click()
      html = render(view)

      assert url_input(html) == "https://first.test/"
    end

    test "close_tab removes the tab and picks a neighbour", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> form("#request-form", request: %{method: "GET", url: "https://first.test/"})
      |> render_change()

      view |> element(~s|button[aria-label="New tab"]|) |> render_click()

      view
      |> form("#request-form", request: %{method: "POST", url: "https://second.test/"})
      |> render_change()

      second_id = active_tab_id(render(view))

      view
      |> element(~s|button[phx-click="close_tab"][phx-value-id="#{second_id}"]|)
      |> render_click()

      html = render(view)

      assert tab_count(html) == 1
      assert url_input(html) == "https://first.test/"
      refute html =~ "https://second.test/"
    end

    test "closing the last tab seeds a fresh Untitled", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> form("#request-form", request: %{method: "GET", url: "https://only.test/"})
      |> render_change()

      id = active_tab_id(render(view))

      view |> element(~s|button[phx-click="close_tab"][phx-value-id="#{id}"]|) |> render_click()
      html = render(view)

      assert tab_count(html) == 1
      assert url_input(html) == ""
      assert html =~ "Untitled"
    end

    test "responses are stored per tab — switching tabs swaps the response panel", %{conn: conn} do
      FakeHttpExecutor.stage(%Response{
        status: 201,
        headers: [{"content-type", "application/json"}],
        body: ~s({"created":true}),
        body_decoded: %{"created" => true},
        duration_ms: 9,
        size_bytes: 16
      })

      {:ok, view, _html} = live(conn, "/")

      first_id = active_tab_id(render(view))

      view
      |> form("#request-form", request: %{method: "POST", url: "https://a.test/"})
      |> render_submit()

      _ = await_response(view)
      assert render(view) =~ ">201<"

      view |> element(~s|button[aria-label="New tab"]|) |> render_click()
      html_b = render(view)

      refute html_b =~ ">201<"
      assert html_b =~ "No response yet"

      view |> element(~s|button[phx-click="select_tab"][phx-value-id="#{first_id}"]|) |> render_click()
      html_back = render(view)

      assert html_back =~ ">201<"
    end
  end

  describe "collections sidebar (with real repo)" do
    alias TestFlowPhx.Infrastructure.Storage.JsonFileRepo
    alias TestFlowPhx.UseCases.Collections

    setup do
      tmp = Path.join(System.tmp_dir!(), "tester_live_repo_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      start_supervised!(
        {JsonFileRepo,
         name: JsonFileRepo, path: Path.join(tmp, "state.json"), flush_after_ms: 5}
      )

      :ok
    end

    test "shows existing collections on mount", %{conn: conn} do
      Collections.create("Smoke API")

      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Smoke API"
      refute html =~ "Sin colecciones"
    end

    test "new_collection creates and lists it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        view
        |> form("form[phx-submit=new_collection]", %{"name" => "Fresh"})
        |> render_submit()

      assert html =~ "Fresh"
    end

    test "delete_collection removes it from the list", %{conn: conn} do
      coll = Collections.create("To Delete")

      {:ok, view, _html} = live(conn, "/")
      assert render(view) =~ "To Delete"

      html =
        view
        |> element(~s|button[phx-click="delete_collection"][phx-value-id="#{coll.id}"]|)
        |> render_click()

      refute html =~ "To Delete"
    end

    test "rename flow updates the name", %{conn: conn} do
      coll = Collections.create("Old")

      {:ok, view, _html} = live(conn, "/")

      view
      |> element(~s|button[phx-click="start_rename_collection"][phx-value-id="#{coll.id}"]|)
      |> render_click()

      html =
        view
        |> form(~s|form[phx-submit=commit_rename_collection][phx-value-id="#{coll.id}"]|,
          %{"name" => "Brand New"}
        )
        |> render_submit()

      assert html =~ "Brand New"
      refute html =~ ">Old<"
    end

    test "open_request_in_tab opens the saved request as a new active tab", %{conn: conn} do
      coll = Collections.create("Stash")

      req =
        Collections.add_request(
          coll.id,
          Request.new(id: "saved-1", name: "Ping", method: "GET", url: "https://x.test/ping")
        )

      {:ok, view, _html} = live(conn, "/")

      view
      |> element(~s|button[phx-click="toggle_collection"][phx-value-id="#{coll.id}"]|)
      |> render_click()

      html =
        view
        |> element(
          ~s|button[phx-click="open_request_in_tab"][phx-value-request-id="#{req.id}"]|
        )
        |> render_click()

      assert html =~ "https://x.test/ping"
      # New tab id is a fresh one — saved request id never becomes a tab id.
      refute html =~ ~s(name="active_tab_id" value="saved-1")
    end

    test "save modal opens, lists existing collections, and persists request", %{conn: conn} do
      coll = Collections.create("Target")

      {:ok, view, _html} = live(conn, "/")

      view
      |> form("#request-form", request: %{method: "POST", url: "https://api.test/x"})
      |> render_change()

      modal_html =
        view |> element(~s|button[phx-click="open_save_modal"]|) |> render_click()

      assert modal_html =~ "Guardar request"
      assert modal_html =~ "Target"
      assert modal_html =~ "POST https://api.test/x"

      view
      |> form("#save-request-form",
        save: %{name: "My Saved", target: coll.id}
      )
      |> render_submit()

      reloaded = Collections.list() |> Enum.find(&(&1.id == coll.id))
      assert [%{name: "My Saved", url: "https://api.test/x", method: "POST"}] = reloaded.requests
    end

    test "sending a request adds an entry to the history sidebar", %{conn: conn} do
      FakeHttpExecutor.stage(%Response{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body: ~s({"hello":"world"}),
        body_decoded: %{"hello" => "world"},
        duration_ms: 12,
        size_bytes: 18
      })

      {:ok, view, _html} = live(conn, "/")

      view
      |> form("#request-form", request: %{method: "GET", url: "https://example.test/x"})
      |> render_submit()

      _ = await_response(view)

      html = view |> element("aside button", "History") |> render_click()

      assert html =~ "https://example.test/x"
      refute html =~ "Sin historial"
    end

    test "open_history_in_tab spawns a new tab from the historical request", %{conn: conn} do
      FakeHttpExecutor.stage(%Response{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body: ~s({"a":1}),
        duration_ms: 3
      })

      {:ok, view, _html} = live(conn, "/")

      view
      |> form("#request-form", request: %{method: "POST", url: "https://api.test/users"})
      |> render_submit()

      _ = await_response(view)

      view |> element("aside button", "History") |> render_click()

      [entry | _] = TestFlowPhx.UseCases.History.list(10)

      view
      |> element(~s|button[phx-click="open_history_in_tab"][phx-value-id="#{entry.id}"]|)
      |> render_click()

      html = render(view)

      assert tab_count(html) >= 2
      assert html =~ "https://api.test/users"
    end

    test "clear_history empties the sidebar", %{conn: conn} do
      FakeHttpExecutor.stage(%Response{status: 200, body: ~s({"x":1}), duration_ms: 1})
      {:ok, view, _html} = live(conn, "/")

      view
      |> form("#request-form", request: %{method: "GET", url: "https://x.test/"})
      |> render_submit()

      _ = await_response(view)

      view |> element("aside button", "History") |> render_click()
      refute render(view) =~ "Sin historial"

      view |> element(~s|button[phx-click="clear_history"]|) |> render_click()

      assert render(view) =~ "Sin historial"
    end

    test "save modal creates a new collection inline when :new is chosen", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> form("#request-form", request: %{method: "GET", url: "https://api.test/users"})
      |> render_change()

      view |> element(~s|button[phx-click="open_save_modal"]|) |> render_click()

      view
      |> form("#save-request-form",
        save: %{name: "List Users", target: "new", new_name: "Brand New Col"}
      )
      |> render_submit()

      [coll] = Collections.list()
      assert coll.name == "Brand New Col"
      assert [%{name: "List Users"}] = coll.requests
    end
  end

  defp await_response(view) do
    Process.sleep(50)
    render(view)
  end

  describe "density toggle" do
    test "mount defaults to :standard and renders the three-option control", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ ~s(id="density-toggle")
      assert html =~ ~s(phx-value-density="compact")
      assert html =~ ~s(phx-value-density="standard")
      assert html =~ ~s(phx-value-density="fluid")
    end

    test "set_density pushes the density to the JS hook", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element(~s|button[phx-value-density="compact"]|)
      |> render_click()

      assert_push_event(view, "density:set", %{density: "compact"})
      assert render(view) =~ ~r/phx-value-density="compact"[^>]*class="[^"]*bg-zinc-900/
    end

    test "density:current hook event updates the assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      html = render_hook(view, "density:current", %{"density" => "fluid"})
      assert html =~ ~r/phx-value-density="fluid"[^>]*class="[^"]*bg-zinc-900/
    end
  end

  describe "theme toggle" do
    test "mount defaults to :system and renders the three-option control", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ ~s(id="theme-toggle")
      assert html =~ ~s(phx-value-theme="light")
      assert html =~ ~s(phx-value-theme="system")
      assert html =~ ~s(phx-value-theme="dark")
    end

    test "theme:current hook event updates the assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      html = render_hook(view, "theme:current", %{"theme" => "dark"})
      # Active option for :dark gets the active-bg styling.
      assert html =~ ~r/phx-value-theme="dark"[^>]*class="[^"]*bg-zinc-900/
    end

    test "set_theme pushes the theme to the JS hook and updates the assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element(~s|button[phx-value-theme="light"]|)
      |> render_click()

      assert_push_event(view, "theme:set", %{theme: "light"})
      assert render(view) =~ ~r/phx-value-theme="light"[^>]*class="[^"]*bg-zinc-900/
    end
  end

  describe "keyboard shortcuts" do
    test "Ctrl+Enter submits the active request", %{conn: conn} do
      FakeHttpExecutor.stage(%Response{
        status: 204,
        headers: [],
        body: "",
        duration_ms: 1,
        size_bytes: 0
      })

      {:ok, view, _html} = live(conn, "/")

      view
      |> form("#request-form", request: %{method: "GET", url: "https://hk.test/x"})
      |> render_change()

      render_hook(view, "hotkey", %{
        "key" => "Enter",
        "ctrlKey" => true,
        "metaKey" => false,
        "altKey" => false
      })

      html = await_response(view)
      assert html =~ ">204<"
    end

    test "Alt+N opens a new tab", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")
      assert tab_count(html) == 1

      html_after =
        render_hook(view, "hotkey", %{
          "key" => "n",
          "ctrlKey" => false,
          "metaKey" => false,
          "altKey" => true
        })

      assert tab_count(html_after) == 2
    end

    test "Alt+W closes the active tab (and seeds a fresh one when it was the last)", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")
      first_id = active_tab_id(html)

      # Open a second tab so we can close the first.
      render_hook(view, "hotkey", %{
        "key" => "n",
        "ctrlKey" => false,
        "metaKey" => false,
        "altKey" => true
      })

      # Re-select the first tab so it's the active one.
      view |> element("button[phx-click='select_tab'][phx-value-id='#{first_id}']") |> render_click()

      html_after =
        render_hook(view, "hotkey", %{
          "key" => "w",
          "ctrlKey" => false,
          "metaKey" => false,
          "altKey" => true
        })

      assert tab_count(html_after) == 1
      refute active_tab_id(html_after) == first_id
    end

    test "plain Enter without modifier does not submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> form("#request-form", request: %{method: "GET", url: "https://hk.test/x"})
      |> render_change()

      render_hook(view, "hotkey", %{
        "key" => "Enter",
        "ctrlKey" => false,
        "metaKey" => false,
        "altKey" => false
      })

      # No response should appear (no FakeHttpExecutor stage either, but the
      # task would still run if send fired — assert by absence of status pill).
      refute render(view) =~ ~r/>\d{3}</
    end
  end

  describe "copy as cURL" do
    test "shows transient 'Copied!' label after clicking the cURL button", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert html =~ "cURL"
      refute html =~ "Copied!"

      view
      |> element("#copy-curl-btn")
      |> render_click()

      html_after = render(view)
      assert html_after =~ "Copied!"

      # The transient label clears on the :clear_curl_copied message.
      send(view.pid, :clear_curl_copied)
      assert render(view) =~ "cURL"
    end

    test "push_event sends the curl string to the clipboard hook", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Type a URL via the form change so the active request has something to copy.
      view
      |> element("form#request-form")
      |> render_change(%{
        "request" => %{
          "method" => "POST",
          "url" => "https://api.test/items",
          "body_type" => "raw",
          "body_text" => "hello"
        }
      })

      assert render_hook(view |> element("#copy-curl-btn"), "copy_as_curl", %{}) =~ "Copied!"
      assert_push_event(view, "clipboard:copy", %{text: text})
      assert text =~ "curl"
      assert text =~ "-X POST"
      assert text =~ "'https://api.test/items'"
      assert text =~ "--data-raw 'hello'"
    end
  end

  defp active_tab_id(html) do
    [_, id] = Regex.run(~r/name="active_tab_id" value="([^"]+)"/, html)
    id
  end

  defp tab_count(html) do
    Regex.scan(~r/phx-click="close_tab"/, html) |> length()
  end

  defp url_input(html) do
    case Regex.run(~r/name="request\[url\]"\s+value="([^"]*)"/, html) do
      [_, v] -> v
      nil -> nil
    end
  end
end
