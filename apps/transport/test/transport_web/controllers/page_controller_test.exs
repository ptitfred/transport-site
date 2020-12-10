defmodule TransportWeb.PageControllerTest do
  use TransportWeb.ConnCase, async: true
  use TransportWeb.DatabaseCase, cleanup: []
  import Plug.Test, only: [init_test_session: 2]
  import Mock

  doctest TransportWeb.PageController

  test "GET /", %{conn: conn} do
    conn = conn |> get(page_path(conn, :index))
    assert html_response(conn, 200) =~ "disponible, valoriser et améliorer"
  end

  describe "GET /espace_producteur" do
    test "requires authentication", %{conn: conn} do
      conn =
        conn
        |> get(page_path(conn, :espace_producteur))

      assert redirected_to(conn, 302) =~ "/login"
    end

    test "renders successfully when data gouv returns no error", %{conn: conn} do
      ud = Repo.insert!(%Dataset{title: "User Dataset", datagouv_id: "123"})
      uod = Repo.insert!(%Dataset{title: "Org Dataset", datagouv_id: "456"})

      # TODO: avoid stubbing at such a high level, instead we should use a low-level (oauth client) stub
      with_mock Dataset, user_datasets: fn _ -> {:ok, [ud]} end, user_org_datasets: fn _ -> {:ok, [uod]} end do
        conn =
          conn
          |> init_test_session(current_user: %{})
          |> get(page_path(conn, :espace_producteur))

        body = html_response(conn, 200)

        {:ok, doc} = Floki.parse_document(body)
        assert Floki.find(doc, ".message--error") == []
        assert Floki.find(doc, ".dataset-item strong") |> Enum.map(&Floki.text(&1)) == ["User Dataset", "Org Dataset"]
      end
    end

    test "renders a degraded mode when data gouv returns error", %{conn: conn} do
      with_mock Sentry, capture_exception: fn _ -> nil end do
        with_mock Dataset,
          user_datasets: fn _ -> {:error, "BAD"} end,
          user_org_datasets: fn _ -> {:error, "SOMETHING"} end do
          conn =
            conn
            |> init_test_session(current_user: %{})
            |> get(page_path(conn, :espace_producteur))

          body = html_response(conn, 200)

          {:ok, doc} = Floki.parse_document(body)
          assert Floki.find(doc, ".dataset-item") |> length == 0

          assert Floki.find(doc, ".message--error") |> Floki.text() ==
                   "Une erreur a eu lieu lors de la récupération de vos ressources"
        end

        history = call_history(Sentry) |> Enum.map(&elem(&1, 1))

        # we want to be notified
        assert history == [
                 {Sentry, :capture_exception, [error: "BAD"]},
                 {Sentry, :capture_exception, [error: "SOMETHING"]}
               ]
      end
    end
  end
end
