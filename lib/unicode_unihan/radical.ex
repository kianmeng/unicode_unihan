defmodule Unicode.Unihan.Radical do
  @moduledoc """
  `Unicode.Unihan.Radical` encapsulates the mapping from CJK radical numbers
  to characters.

  """
  alias Unicode.Unihan.Utils

  @radicals Utils.parse_radicals()
  @max_radical Map.keys(@radicals) |> Enum.max()

  def radicals do
    @radicals
  end

  @doc """
  Returns grapheme associated with the radical,
  as specified in the [CJK Radicals](https://www.unicode.org/reports/tr41/tr41-30.html#CJKRadicals) file.

  ### Arguments

  * `index` is the Unicode radical number (1..214), reported from various
    radical stroke properties such as `kRSUnicode`.

  * an optional argument, which can be one of:
    * `:unified_ideograph` (default) shows the grapheme in the (normal) CJK
       unified ideograph Unicode block (hexadecimal 4000--6000)
    * `:radical_character` shows the grapheme in the special, contiguous
       KangXi Radical block (2F00--2FD5)
    * `:all` returns the full map for the radical

  ### Examples

      iex> Unicode.Unihan.Radical.radical(72)
      "日"

      iex> Unicode.Unihan.Radical.radical(72, :unified_ideograph)
      "日"

      iex> Unicode.Unihan.Radical.radical(72, :radical_character)
      "⽇"

      iex> Unicode.Unihan.Radical.radical(72, :unified_ideograph) == Unicode.Unihan.Radical.radical(72, :radical_character)
      false

      iex> Unicode.Unihan.Radical.radical(72, :simplified)
      false

      iex> Unicode.Unihan.Radical.radical(72, :all)
      %{
        Hans: %{radical_character: 12103, radical_number: 72, unified_ideograph: 26085},
        Hant: %{radical_character: 12103, radical_number: 72, unified_ideograph: 26085}
      }

  """
  def radical(index, key \\ :unified_ideograph)

  def radical(index, :unified_ideograph) when index in 1..@max_radical do
    radicals()
    |> Map.get(index)
    # |> Map.get(:unified_ideograph)
    # |> Unicode.Unihan.to_string()
  end

  def radical(index, :radical_character) when index in 1..@max_radical do
    radicals()
    |> Map.get(index)
    # |> Map.get(:radical_character)
    # |> Unicode.Unihan.to_string()
  end

  def radical(index, :simplified) when index in 1..@max_radical do
    radicals()
    |> Map.get(index)
    # |> Map.get(:simplified)
    # |> Unicode.Unihan.to_string()
  end

  def radical(index, :all) when index in 1..@max_radical do
    Map.get(radicals(), index)
  end

  def radical(index, _) when not is_integer(index) do
    {:error, "Invalid radical number. Valid numbers are an integer in the range 1..#{inspect @max_radical}"}
  end

  def radical(_index, attr) do
    {:error,
      "Invalid attribute. Valid attributes are :unified_ideograph, :radical_character, :simplified, :all. " <>
      "Found #{inspect attr}"
    }
  end

  @doc """
  Filter the Unicode CJK radical database returning selected
  codepoints.

  ### Arguments

  * `fun` is a `1-arity` function that is passed
    the attribute map for a given codepoint. if the
    function returns a `truthy` value then the codepoint
    is included in the returned data. If the return
    value is `falsy` then the codepoint is ommitted
    from the returned list.

  ### Returns

  * a map of the filtered codepoints mapped to their
    attributes.

  ### Example

      iex> Unicode.Unihan.Radical.filter(&(&1[:simplified] == true))
      ...> |> Enum.count()
      26

      iex> Unicode.Unihan.Radical.filter(&(&1[:radical_number] < 5))
      ...> |> Enum.count()
      4

  """
  def filter(fun) when is_function(fun, 1) do
    Enum.filter(radicals(), fn {_radical_number, value} ->
      fun.(value)
    end)
    |> Map.new()
  end

  @doc """
  Filter the Unicode CJK radical database returning selected
  codepoints that are not rejected by the provided
  function.

  ### Arguments

  * `fun` is a `1-arity` function that is passed
    the attribute map for a given codepoint. if the
    function returns a `falsy` value then the codepoint
    is included in the returned data. If the return
    value is `truthy` then the codepoint is ommitted
    from the returned list.

  ### Returns

  * a map of the codepoints that are not rejected
    mapped to their attributes.

  ### Example

      iex> Unicode.Unihan.Radical.reject(&(&1[:simplified] == true))
      ...> |> Enum.count()
      188

      iex> Unicode.Unihan.Radical.reject(&(&1[:radical_number] < 5))
      ...> |> Enum.count()
      210

  """
  def reject(fun) when is_function(fun, 1) do
    Enum.reject(radicals(), fn {_radical_number, value} ->
      fun.(value)
    end)
    |> Map.new()
  end
end
