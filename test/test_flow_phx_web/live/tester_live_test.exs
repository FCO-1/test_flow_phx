defmodule TestFlowPhxWeb.TesterLiveTest do
  use TestFlowPhxWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "GET / mounts the TesterLive with the shell rendered", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "TestFlow"
    assert html =~ "Probador local de endpoints REST"
    assert html =~ "Collections"
    assert html =~ "History"
  end

  test "shows the Collections panel by default and toggles to History", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert render(view) =~ "añade colecciones"

    rendered =
      view
      |> element("button", "History")
      |> render_click()

    assert rendered =~ "el historial aparece"
    refute rendered =~ "añade colecciones"
  end

  test "renders the active request method and url placeholders", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~s(<dd class="font-mono">GET</dd>)
    assert html =~ "in_flight?"
  end
end
