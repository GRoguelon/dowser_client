defmodule Dowser.Client.HTTP.ProfileTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.HTTP.Profile

  setup do
    on_exit(fn -> Profile.invalidate(:dowser_profile_test) end)

    :ok
  end

  describe "ensure_started/2" do
    test "starts a profile and applies the default options" do
      assert {:ok, :dowser_profile_test} = Profile.ensure_started(:dowser_profile_test)

      options = options(:dowser_profile_test)

      assert options[:max_sessions] == 20
      assert options[:max_keep_alive_length] == 100
      assert options[:keep_alive_timeout] == 120_000
      assert options[:cookies] == :disabled
    end

    test "options override the defaults" do
      assert {:ok, _profile} =
               Profile.ensure_started(:dowser_profile_test,
                 max_sessions: 7,
                 pipeline_timeout: 1_000
               )

      options = options(:dowser_profile_test)

      assert options[:max_sessions] == 7
      assert options[:pipeline_timeout] == 1_000
      assert options[:max_keep_alive_length] == 100
    end

    test "is idempotent, and does not re-apply options once started" do
      assert {:ok, _profile} = Profile.ensure_started(:dowser_profile_test, max_sessions: 7)
      assert {:ok, _profile} = Profile.ensure_started(:dowser_profile_test, max_sessions: 9)

      assert options(:dowser_profile_test)[:max_sessions] == 7
    end

    test "rejects invalid profile options" do
      assert {:error, {:invalid_profile_opts, _reason}} =
               Profile.ensure_started(:dowser_profile_test, max_sessions: :lots)
    end

    test "rejects a non-atom profile name" do
      assert {:error, {:invalid_profile, "nope"}} = Profile.ensure_started("nope")
    end
  end

  describe "reset/2" do
    test "re-applies options to an already-started profile" do
      assert {:ok, _profile} = Profile.ensure_started(:dowser_profile_test, max_sessions: 7)
      assert {:ok, _profile} = Profile.reset(:dowser_profile_test, max_sessions: 9)

      assert options(:dowser_profile_test)[:max_sessions] == 9
    end
  end

  describe "info/1" do
    test "reports an unknown profile rather than exiting" do
      assert {:error, {:not_started, :dowser_profile_never_started}} =
               Profile.info(:dowser_profile_never_started)
    end
  end

  defp options(profile) do
    profile |> Profile.info() |> Keyword.fetch!(:options)
  end
end
