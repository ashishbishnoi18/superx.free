defmodule SuperX.Billing.StripeEventsTest do
  @moduledoc """
  Applying a Stripe event decides whether someone keeps the plan they paid
  for, so both directions are pinned: granting on payment and dropping on
  cancellation.
  """

  use SuperX.DataCase, async: true

  import SuperX.Fixtures

  alias SuperX.Billing

  describe "apply_stripe_event/1" do
    test "a completed checkout puts the buyer on the paid plan" do
      %{user: user} = user_fixture()

      assert {:ok, _subscription} =
               Billing.apply_stripe_event(%{
                 "type" => "checkout.session.completed",
                 "data" => %{
                   "object" => %{
                     "client_reference_id" => user.id,
                     "customer" => "cus_1",
                     "subscription" => "sub_1"
                   }
                 }
               })

      assert Billing.tier(user) == "ultra"
    end

    test "a cancellation drops the plan without touching anyone else" do
      %{user: paying} = user_fixture()
      %{user: bystander} = user_fixture()

      {:ok, _} =
        Billing.apply_stripe_event(%{
          "type" => "checkout.session.completed",
          "data" => %{
            "object" => %{
              "client_reference_id" => paying.id,
              "customer" => "cus_2",
              "subscription" => "sub_2"
            }
          }
        })

      # Stripe raises this one from the portal with no metadata of ours, so
      # the customer id is the only link back to the user.
      assert {:ok, _} =
               Billing.apply_stripe_event(%{
                 "type" => "customer.subscription.deleted",
                 "data" => %{
                   "object" => %{
                     "id" => "sub_2",
                     "customer" => "cus_2",
                     "status" => "canceled"
                   }
                 }
               })

      assert Billing.tier(paying) == "free"
      assert Billing.tier(bystander) == "free"
    end

    test "an unknown customer cannot move a stranger's subscription" do
      %{user: user} = user_fixture()

      {:ok, _} =
        Billing.apply_stripe_event(%{
          "type" => "checkout.session.completed",
          "data" => %{
            "object" => %{
              "client_reference_id" => user.id,
              "customer" => "cus_3",
              "subscription" => "sub_3"
            }
          }
        })

      assert {:ok, :ignored} =
               Billing.apply_stripe_event(%{
                 "type" => "customer.subscription.deleted",
                 "data" => %{
                   "object" => %{
                     "id" => "sub_x",
                     "customer" => "cus_unknown",
                     "status" => "canceled"
                   }
                 }
               })

      assert Billing.tier(user) == "ultra"
    end

    test "an event type this app ignores still succeeds" do
      # Stripe retries anything that is not 2xx, so an unhandled type has to
      # be a success or it queues forever.
      assert {:ok, :ignored} =
               Billing.apply_stripe_event(%{
                 "type" => "invoice.upcoming",
                 "data" => %{"object" => %{}}
               })
    end
  end
end
