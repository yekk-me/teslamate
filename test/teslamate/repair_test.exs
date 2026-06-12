defmodule TeslaMate.RepairTest do
  use TeslaMate.DataCase, async: false

  alias TeslaMate.Repair

  test "supports named repair workers" do
    name = :"repair_#{System.unique_integer([:positive])}"

    start_supervised!({Repair, name: name, limit: 0, interval: :timer.hours(1)})

    assert :ok = Repair.trigger_run(name)
  end
end
