defmodule TestFlowPhxWeb.TesterLiveTest do
  use TestFlowPhxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TestFlowPhx.Domain.Response
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

      assert render(view) =~ "añade colecciones"

      assert view
             |> element("aside button", "History")
             |> render_click() =~ "el historial aparece"
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

  defp await_response(view) do
    Process.sleep(50)
    render(view)
  end
end
