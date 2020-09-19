defmodule Opencov.JobManager do
  use Opencov.Web, :manager

  import Ecto.Query
  import Opencov.Job
  alias Opencov.Job
  alias Opencov.FileManager
  require Logger

  @required_fields ~w(build_id)a
  @optional_fields ~w(run_at job_number files_count)a

  def changeset(model, params \\ :invalid) do
    model
    |> cast(params, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> prepare_changes(&check_job_number/1)
    |> prepare_changes(&set_previous_values/1)
  end

  defp check_job_number(changeset) do
    if get_change(changeset, :job_number) do
      changeset
    else
      set_job_number(changeset)
    end
  end

  defp set_job_number(changeset) do
    build_id = get_change(changeset, :build_id) || changeset.data.build_id
    job = Job |> for_build(build_id) |> order_by(desc: :job_number) |> Repo.first
    job_number = if job, do: job.job_number + 1, else: 1
    put_change(changeset, :job_number, job_number)
  end

  defp set_previous_values(changeset) do
    build_id = get_change(changeset, :build_id) || changeset.data.build_id
    job_number = get_change(changeset, :job_number)
    previous_build_id = Opencov.Repo.get!(Opencov.Build, build_id).previous_build_id
    previous_job = search_previous_job(previous_build_id, job_number)
    if previous_job do
      change(changeset, %{previous_job_id: previous_job.id, previous_coverage: previous_job.coverage})
    else
      changeset
    end
  end

  defp search_previous_job(nil, _), do: nil
  defp search_previous_job(previous_build_id, job_number),
    do: Job |> for_build(previous_build_id) |> where(job_number: ^job_number) |> Repo.first

  def update_coverage(job) do
    job = change(job, coverage: compute_coverage(job)) |> Repo.update! |> Repo.preload(:build)
    Opencov.BuildManager.update_coverage(job.build)
    job
  end

  def create_from_json!(build, params) do
    {source_files, params} = Map.pop(params, "source_files", [])
    params = Map.put(params, "files_count", Enum.count(source_files))

    if Map.has_key?(params, "run_at") && is_php_coveralls_date(params["run_at"]) do
      Logger.debug "Got run_at date from php-coveralls, transform it."
      # php-coveralls send run_at date in Y-m-d H:i:s O format. But we will got an 422 in that case
      # so we should convert it to iso8601
      #
      # Example: 2020-09-18 10:37:30 +0000
      params = Map.put(params, "run_at", Timex.format!(Timex.parse!(params["run_at"], "{YYYY}-{M}-{D} {h24}:{m}:{s} {Z}"), "{ISO:Extended}"))
    end

    Logger.debug inspect(params)

    job = Ecto.build_assoc(build, :jobs) |> changeset(params) |> Repo.insert!
    Enum.each source_files, fn file_params ->
      Ecto.build_assoc(job, :files) |> FileManager.changeset(file_params) |> Repo.insert!
    end
    job |> Repo.preload(:files) |> update_coverage
  end

  def is_php_coveralls_date(date) do
    case Timex.parse(date, "{YYYY}-{M}-{D} {h24}:{m}:{s} {Z}") do
      {:ok, _} -> true
      _ -> false
    end
  end
end
