defmodule Absinthe.Pipeline do

  alias Absinthe.Phase

  require Logger

  @type data_t :: any

  @type phase_config_t :: Phase.t | {Phase.t, Keyword.t}

  @type t :: [phase_config_t | [phase_config_t]]

  @spec run(data_t, t) :: {:ok, data_t, [Phase.t]} | {:error, String.t, [Phase.t]}
  def run(input, pipeline) do
    List.flatten(pipeline)
    |> run_phase(input)
  end

  @defaults [
    adapter: Absinthe.Adapter.LanguageConventions,
    operation_name: nil,
    variables: %{},
    context: %{},
    root_value: %{},
    validation_result_phase: Phase.Document.Validation.Result,
    result_phase: Phase.Document.Result,
    jump_phases: true,
  ]

  @spec for_document(Absinthe.Schema.t) :: t
  @spec for_document(Absinthe.Schema.t, Keyword.t) :: t
  def for_document(schema, options \\ []) do
    options = @defaults
    |> Keyword.merge(Keyword.put(options, :schema, schema))
    [
      # Parse Document
      {Phase.Parse, options},
      # Convert to Blueprint
      Phase.Blueprint,
      # Find Current Operation (if any)
      {Phase.Document.Validation.ProvidedAnOperation, options},
      {Phase.Document.CurrentOperation, options},
      # Mark Fragment/Variable Usage
      Phase.Document.Uses,
      # Validate Document Structure
      {Phase.Document.Validation.NoFragmentCycles, options},
      Phase.Document.Validation.LoneAnonymousOperation,
      Phase.Document.Validation.SelectedCurrentOperation,
      Phase.Document.Validation.KnownFragmentNames,
      Phase.Document.Validation.NoUndefinedVariables,
      Phase.Document.Validation.NoUnusedVariables,
      Phase.Document.Validation.UniqueFragmentNames,
      Phase.Document.Validation.UniqueOperationNames,
      Phase.Document.Validation.UniqueVariableNames,
      # Apply Input
      {Phase.Document.Variables, options},
      Phase.Document.Arguments.Normalize,
      # Map to Schema
      {Phase.Schema, options},
      # Ensure Types
      Phase.Validation.KnownTypeNames,
      # Process Arguments
      Phase.Document.Arguments.Coercion,
      Phase.Document.Arguments.Data,
      Phase.Document.Arguments.Defaults,
      # Validate Full Document
      Phase.Validation.KnownDirectives,
      Phase.Document.Validation.ScalarLeafs,
      Phase.Document.Validation.VariablesAreInputTypes,
      Phase.Document.Validation.ArgumentsOfCorrectType,
      Phase.Document.Validation.KnownArgumentNames,
      Phase.Document.Validation.ProvidedNonNullArguments,
      Phase.Document.Validation.UniqueArgumentNames,
      Phase.Document.Validation.UniqueInputFieldNames,
      Phase.Document.Validation.FieldsOnCorrectType,
      # Check Validation
      {Phase.Document.Validation.Result, options},
      # Apply Directives
      Phase.Document.Directives,
      # Prepare for Execution
      Phase.Document.CascadeInvalid,
      Phase.Document.Flatten,
      Phase.Debug,
      # Execution
      {Phase.Document.Execution.Resolution, options},
      # Format Result
      Phase.Document.Result
    ]
  end

  @defaults [
    adapter: Absinthe.Adapter.LanguageConventions
  ]

  @spec for_schema(nil | Absinthe.Schema.t) :: t
  @spec for_schema(nil | Absinthe.Schema.t, Keyword.t) :: t
  def for_schema(prototype_schema, options \\ []) do
    options = @defaults
    |> Keyword.merge(Keyword.put(options, :schema, prototype_schema))
    [
      Phase.Parse,
      Phase.Blueprint,
      {Phase.Schema, options},
      Phase.Validation.KnownTypeNames,
      Phase.Validation.KnownDirectives
    ]
  end

  @doc """
  Return the part of a pipeline before a specific phase.
  """
  @spec before(t, atom) :: t
  def before(pipeline, phase) do
    result = List.flatten(pipeline)
    |> Enum.take_while(&(!match_phase?(phase, &1)))
    case result do
      ^pipeline ->
        raise RuntimeError, "Could not find phase #{phase}"
      _ ->
        result
    end
  end

  @doc """
  Return the part of a pipeline after (and including) a specific phase.
  """
  @spec from(t, atom) :: t
  def from(pipeline, phase) do
    result = List.flatten(pipeline)
    |> Enum.drop_while(&(!match_phase?(phase, &1)))
    case result do
      [] ->
        raise RuntimeError, "Could not find phase #{phase}"
      _ ->
        result
    end
  end

  # Whether a phase configuration is for a given phase
  @spec match_phase?(Phase.t, phase_config_t) :: boolean
  defp match_phase?(phase, phase), do: true
  defp match_phase?(phase, {phase, _}), do: true
  defp match_phase?(_, _), do: false

  @doc """
  Return the part of a pipeline up to and including a specific phase.
  """
  @spec upto(t, atom) :: t
  def upto(pipeline, phase) do
    beginning = before(pipeline, phase)
    item = get_in(pipeline, [Access.at(length(beginning))])
    beginning ++ [item]
  end

  @spec without(t, Phase.t) :: t
  def without(pipeline, phase) do
    pipeline
    |> Enum.filter(&(match_phase?(phase, &1)))
  end

  @spec insert_before(t, Phase.t, Phase.t) :: t
  def insert_before(pipeline, phase, additional) do
    beginning = before(pipeline, phase)
    beginning ++ [additional] ++ (pipeline -- beginning)
  end

  @spec insert_before(t, Phase.t, Phase.t) :: t
  def insert_after(pipeline, phase, additional) do
    beginning = upto(pipeline, phase)
    beginning ++ [additional] ++ (pipeline -- beginning)
  end

  @spec reject(t, Regex.t) :: t
  def reject(pipeline, pattern) do
    Enum.reject(pipeline, fn
      {phase, _} ->
        Regex.match?(pattern, Atom.to_string(phase))
      phase ->
        Regex.match?(pattern, Atom.to_string(phase))
    end)
  end

  @spec run_phase(t, data_t, [Phase.t]) :: {:ok, data_t, [Phase.t]} | {:error, String.t, [Phase.t]}
  def run_phase(pipeline, input, done \\ [])
  def run_phase([], input, done) do
    {:ok, input, done}
  end
  def run_phase([phase_config | todo], input, done) do
    {phase, options} = phase_invocation(phase_config)
    case phase.run(input, options) do
      {:ok, result} ->
        run_phase(todo, result, [phase | done])
      {:jump, result, destination_phase} when is_atom(destination_phase) ->
        run_phase(from(todo, destination_phase), result, [phase | done])
      {:insert, result, extra_pipeline} ->
        run_phase(List.wrap(extra_pipeline) ++ todo, result, [phase | done])
      {:replace, result, final_pipeline} ->
        run_phase(List.wrap(final_pipeline), result, [phase | done])
      {:error, message} ->
        {:error, message, [phase | done]}
      _ ->
        {:error, "Last phase did not return a valid result tuple.", [phase | done]}
    end
  end

  @spec phase_invocation(phase_config_t) :: {Phase.t, list}
  defp phase_invocation({phase, options}) when is_list(options) do
    {phase, options}
  end
  defp phase_invocation(phase) do
    {phase, []}
  end

end