defmodule CodeCorps.StripeService.StripeConnectSubscriptionService do
  import Ecto.Query

  alias CodeCorps.{
    Project, Repo, StripeConnectCustomer, StripeConnectAccount,
    StripeConnectPlan, StripeConnectSubscription, User
  }
  alias CodeCorps.Services.{DonationGoalsService, ProjectService}
  alias CodeCorps.StripeService.{StripeConnectCardService, StripeConnectCustomerService}
  alias CodeCorps.StripeService.Adapters.StripeConnectSubscriptionAdapter
  alias CodeCorps.StripeService.Validators.{ProjectSubscribable, UserCanSubscribe}

  @api Application.get_env(:code_corps, :stripe)

  def find_or_create(%{"project_id" => project_id, "quantity" => _, "user_id" => user_id} = attributes) do
    with {:ok, %Project{} = project} <- get_project(project_id) |> ProjectSubscribable.validate,
         {:ok, %User{} = user} <- get_user(user_id) |> UserCanSubscribe.validate
    do
      {:ok, %StripeConnectSubscription{} = subscription} = do_find_or_create(project, user, attributes)

      ProjectService.update_project_totals(project)
      DonationGoalsService.update_project_goals(project)

      {:ok, subscription}
    else
      # possible errors
      # {:error, :project_not_ready} - `CodeCorps.ProjectSubscribable.validate/1` failed
      # {:error, :user_not_ready} - `CodeCorps.UserCanSubscribe.validate/1` failed
      # {:error, %Ecto.Changeset{}} - Record creation failed due to validation errors
      # {:error, %Stripe.APIError{}} - Stripe request failed
      # {:error, :not_found} - One of the associated records was not found
      {:error, error} -> {:error, error}
      nil -> {:error, :not_found}
      _ -> {:error, :unexpected}
    end
  end

  def update_from_stripe(stripe_id, connect_customer_id) do
    with {:ok, %StripeConnectAccount{} = connect_account} <- retrieve_connect_account(connect_customer_id),
         {:ok, %Stripe.Subscription{} = stripe_subscription} <- @api.Subscription.retrieve(stripe_id, connect_account: connect_account.id),
         {:ok, %StripeConnectSubscription{} = subscription} <- load_subscription(stripe_id),
         {:ok, params} <- stripe_subscription |> StripeConnectSubscriptionAdapter.to_params(%{}),
         {:ok, %Project{} = project} <- get_project(subscription)
    do
      {:ok, %StripeConnectSubscription{} = subscription} = update_subscription(subscription, params)

      ProjectService.update_project_totals(project)
      DonationGoalsService.update_project_goals(project)

      {:ok, subscription}
    else
      # possible errors
      # {:error, %Ecto.Changeset{}} - Record creation failed due to validation errors
      # {:error, %Stripe.APIError{}} - Stripe request failed
      # {:error, :not_found} - One of the associated records was not found
      {:error, error} -> {:error, error}
      nil -> {:error, :not_found}
      _ -> {:error, :unexpected}
    end
  end

  defp do_find_or_create(%Project{} = project, %User{} = user, %{} = attributes) do
    case find(project, user) do
      nil -> create(project, user, attributes)
      %StripeConnectSubscription{} = subscription -> {:ok, subscription}
    end
  end

  defp find(%Project{} = project, %User{} = user) do
    StripeConnectSubscription
    |> where([s], s.stripe_connect_plan_id == ^project.stripe_connect_plan.id and s.user_id == ^user.id)
    |> Repo.one
  end

  defp create(%Project{} = project, %User{} = user, attributes) do
    with platform_card <- user.stripe_platform_card,
         platform_customer <- user.stripe_platform_customer,
         connect_account <- project.organization.stripe_connect_account,
         plan <- project.stripe_connect_plan,
         {:ok, connect_customer} <- StripeConnectCustomerService.find_or_create(platform_customer, connect_account),
         {:ok, connect_card} <- StripeConnectCardService.find_or_create(platform_card, connect_customer, platform_customer, connect_account),
         create_attributes <- to_create_attributes(connect_card, connect_customer, plan, attributes),
         {:ok, subscription} <- @api.Subscription.create(create_attributes, connect_account: connect_account.id_from_stripe),
         insert_attributes <- to_insert_attributes(attributes, plan),
         {:ok, params} <- StripeConnectSubscriptionAdapter.to_params(subscription, insert_attributes),
         {:ok, %StripeConnectSubscription{} = stripe_connect_subscription} <- insert_subscription(params)
    do
      {:ok, stripe_connect_subscription}
    else
      # just pass failure to caller
      failure -> failure
    end
  end

  defp get_project(%StripeConnectSubscription{stripe_connect_plan_id: stripe_connect_plan_id}) do
    %StripeConnectPlan{project_id: project_id} = Repo.get(StripeConnectPlan, stripe_connect_plan_id)
    {:ok, get_project(project_id, [:stripe_connect_plan])}
  end

  @default_project_preloads [:stripe_connect_plan, [{:organization, :stripe_connect_account}]]

  defp get_project(project_id, preloads \\ @default_project_preloads) do
    Repo.get(Project, project_id) |> Repo.preload(preloads)
  end

  @default_user_preloads [:stripe_platform_customer, [{:stripe_platform_card, :stripe_connect_cards}]]

  defp get_user(user_id, preloads \\ @default_user_preloads) do
    Repo.get(User, user_id) |> Repo.preload(preloads)
  end

  defp insert_subscription(params) do
    %StripeConnectSubscription{}
    |> StripeConnectSubscription.create_changeset(params)
    |> Repo.insert
  end

  defp to_create_attributes(card, customer, plan, %{"quantity" => quantity}) do
    %{
      application_fee_percent: 5,
      customer: customer.id_from_stripe,
      plan: plan.id_from_stripe,
      quantity: quantity,
      source: card.id_from_stripe
    }
  end

  defp to_insert_attributes(attrs, %StripeConnectPlan{id: stripe_connect_plan_id}) do
    attrs |> Map.merge(%{"stripe_connect_plan_id" => stripe_connect_plan_id})
  end

  defp retrieve_connect_account(connect_customer_id) do
    customer =
      StripeConnectCustomer
      |> Repo.get_by(id_from_stripe: connect_customer_id)
      |> Repo.preload(:stripe_connect_account)

    {:ok, customer.stripe_connect_account}
  end

  defp load_subscription(id_from_stripe) do
    subscription = Repo.get_by(StripeConnectSubscription, id_from_stripe: id_from_stripe)

    {:ok, subscription}
  end

  defp update_subscription(%StripeConnectSubscription{} = record, params) do
    record
    |> StripeConnectSubscription.webhook_update_changeset(params)
    |> Repo.update
  end
end
