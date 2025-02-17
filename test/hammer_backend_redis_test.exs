defmodule HammerBackendRedisTest do
  use ExUnit.Case

  setup do
    {Hammer.Backend.Redis, config} = Application.get_env(:hammer, :backend)
    {:ok, pid} = Hammer.Backend.Redis.start_link(config)
    %{redix: redix} = :sys.get_state(pid)

    assert {:ok, "OK"} = Redix.command(redix, ["FLUSHALL"])
    {:ok, [pid: pid, redix: redix]}
  end

  test "count_hit, insert", %{pid: pid, redix: redix} do
    bucket = 1
    id = "one"
    bucket_key = {bucket, id}
    now = 123
    now_str = now |> Integer.to_string()

    assert {:ok, 0} = Redix.command(redix, ["EXISTS", make_redis_key(bucket_key)])
    assert {:ok, 1} == Hammer.Backend.Redis.count_hit(pid, bucket_key, now)
    assert {:ok, 1} = Redix.command(redix, ["EXISTS", make_redis_key(bucket_key)])

    assert {:ok, ["count", "1", "created", ^now_str, "updated", ^now_str]} =
             Redix.command(redix, ["HGETALL", make_redis_key(bucket_key)])
  end

  test "count_hit, insert, with custom increment", %{pid: pid, redix: redix} do
    bucket = 1
    id = "one"
    bucket_key = {bucket, id}
    now = 123
    now_str = now |> Integer.to_string()
    inc = Enum.random(1..100)
    inc_str = inc |> Integer.to_string()

    assert {:ok, inc} == Hammer.Backend.Redis.count_hit(pid, bucket_key, now, inc)
    assert {:ok, 1} = Redix.command(redix, ["EXISTS", make_redis_key(bucket_key)])

    assert {:ok, ["count", ^inc_str, "created", ^now_str, "updated", ^now_str]} =
             Redix.command(redix, ["HGETALL", make_redis_key(bucket_key)])
  end

  test "count_hit, update", %{pid: pid, redix: redix} do
    # 1. set-up
    bucket = 1
    id = "one"
    bucket_key = {bucket, id}
    now_before = 123
    now_before_str = now_before |> Integer.to_string()
    now_after = 456
    now_after_str = now_after |> Integer.to_string()

    assert {:ok, 1} == Hammer.Backend.Redis.count_hit(pid, bucket_key, now_before)
    assert {:ok, 1} = Redix.command(redix, ["EXISTS", make_redis_key(bucket_key)])

    # 2. function call under test: count == 2
    assert {:ok, 2} == Hammer.Backend.Redis.count_hit(pid, bucket_key, now_after)
    assert {:ok, 1} = Redix.command(redix, ["EXISTS", make_redis_key(bucket_key)])

    assert {:ok, ["count", "2", "created", ^now_before_str, "updated", ^now_after_str]} =
             Redix.command(redix, ["HGETALL", make_redis_key(bucket_key)])
  end

  test "get_bucket", %{pid: pid} do
    # 1. set-up
    bucket = 1
    id = "one"
    bucket_key = {bucket, id}

    now_before = 123
    inc_before = Enum.random(1..100)

    now_after = 456
    inc_after = Enum.random(1..100)

    inc_total = inc_before + inc_after

    assert {:ok, ^inc_before} =
             Hammer.Backend.Redis.count_hit(pid, bucket_key, now_before, inc_before)

    assert {:ok, ^inc_total} =
             Hammer.Backend.Redis.count_hit(pid, bucket_key, now_after, inc_after)

    # 2. function call under test
    assert {:ok, {^bucket_key, ^inc_total, ^now_before, ^now_after}} =
             Hammer.Backend.Redis.get_bucket(pid, bucket_key)
  end

  test "delete buckets", %{pid: pid, redix: redix} do
    bucket = 1
    id = "one"
    bucket_key = {bucket, id}
    now = 123

    {:ok, _} = Hammer.Backend.Redis.count_hit(pid, bucket_key, now, 1)
    assert {:ok, 1} = Hammer.Backend.Redis.delete_buckets(pid, id)
    assert {:ok, []} = Redix.command(redix, ["KEYS", "*"])
  end

  test "delete buckets with no keys matching", %{pid: pid, redix: redix} do
    id = "one"
    now = 123

    for bucket <- 1..10 do
      bucket_key = {bucket, id}
      {:ok, _} = Hammer.Backend.Redis.count_hit(pid, bucket_key, now, 1)
    end

    assert {:ok, 0} = Hammer.Backend.Redis.delete_buckets(pid, "foobar")

    # Previous keys remain untouched
    {:ok, keys} = Redix.command(redix, ["KEYS", "*"])
    assert 10 == length(keys)
  end

  test "delete buckets when many buckets exist", %{pid: pid, redix: redix} do
    id = "one"
    now = 123

    for bucket <- 1..1000 do
      bucket_key = {bucket, id}
      {:ok, _} = Hammer.Backend.Redis.count_hit(pid, bucket_key, now, 1)
    end

    assert {:ok, 1_000} = Hammer.Backend.Redis.delete_buckets(pid, id)
    assert {:ok, []} = Redix.command(redix, ["KEYS", "*"])
  end

  test "delete buckets when scan returns empty list but valid cursor", %{pid: pid, redix: redix} do
    # By writing only one key to the keyspace, most iterations of the SCAN call
    # will return a valid cursor but an empty list. The valid cursor should
    # make the delete_buckets call iterate until the intended key is found
    now = 123
    id = "one"
    bucket_key = {1, id}
    {:ok, _} = Hammer.Backend.Redis.count_hit(pid, bucket_key, now, 1)

    another_id = "another"

    for bucket <- 1..1000 do
      bucket_key = {bucket, another_id}
      {:ok, _} = Hammer.Backend.Redis.count_hit(pid, bucket_key, now, 1)
    end

    assert {:ok, 1} = Hammer.Backend.Redis.delete_buckets(pid, id)
    {:ok, keys} = Redix.command(redix, ["KEYS", "*"])
    assert 1_000 == length(keys)
  end

  defp make_redis_key({bucket, id}) do
    "Hammer:Redis:#{id}:#{bucket}"
  end
end
