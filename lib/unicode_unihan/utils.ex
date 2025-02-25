defmodule Unicode.Unihan.Utils do
  @moduledoc """
  Functions to parse the Unicode Unihan database
  files.

  """

  alias Unicode.Unihan.Cantonese

  @data_dir Path.join(__DIR__, "../../data") |> Path.expand()

  @unihan_subdir "unihan"
  @unihan_fields_file "unihan_fields.json"
  @cjk_radicals_file "cjk_radicals.txt"
  @jyutping_index_file "cantonese/jyutping_index.csv"

  @codepoints_file "unihan_codepoints.etf"
  @unihan_codepoints_path Path.join(@data_dir, @codepoints_file)

  @unihan_etf_file "unihan.etf"
  @unihan_etf_path Path.join(@data_dir, @unihan_etf_file)

  for file <- Path.wildcard(Path.join(__DIR__, "../../data/**/**")) do
    @external_resource file
  end

  @external_resource Path.join(@data_dir, @jyutping_index_file) |> Path.expand()
  @external_resource Path.join(@data_dir, @unihan_fields_file) |> Path.expand()
  @external_resource Path.join(@data_dir, @cjk_radicals_file) |> Path.expand()

  @doc false
  def data_dir do
    @data_dir
  end

  @doc false
  def unihan_path do
    @unihan_etf_path
  end

  @doc false
  def unihan_codepoints_path do
    @unihan_codepoints_path
  end

  @doc false
  def save_unihan! do
    unihan = Unicode.Unihan.Utils.parse_files()
    unihan_binary = :erlang.term_to_binary(unihan)
    unihan_path = Unicode.Unihan.Utils.unihan_path()
    File.write!(unihan_path, unihan_binary)
  end

  @doc """
  Parse all Unicode Unihan files and return
  a mapping from codepoint to a map of metadata
  for that codepoint.

  """

  def parse_files do
    @data_dir
    |> Path.join(@unihan_subdir)
    |> File.ls!()
    |> Enum.reduce(%{}, &parse_file(&1, &2))
  end

  @doc """
  Parse one Unicode Unihan file and return
  a mapping from codepoint to a map of metadata
  for that codepoint.

  """
  def parse_file(file, map \\ %{}) do
    path = Path.join(@data_dir, [@unihan_subdir, "/", file])
    fields = unihan_fields()

    Enum.reduce(File.stream!(path), map, fn line, map ->
      case line do
        <<"#", _rest::bitstring>> ->
          map

        <<"\n", _rest::bitstring>> ->
          map

        data ->
          [codepoint, key, value] =
            data
            |> String.split("\t")
            |> Enum.map(&String.trim/1)

          codepoint = decode_codepoint(codepoint)

          Map.get_and_update(map, codepoint, fn
            nil ->
              {key, value} = decode_metadata(key, value, fields)
              {nil, %{key => value, :codepoint => codepoint}}

            current_value when is_map(current_value) ->
              {key, value} = decode_metadata(key, value, fields)
              {current_value, Map.put(current_value, key, value)}
          end)
          |> elem(1)
      end
    end)
  end

  @doc """
  Returns a map of the field definitions for a
  Unihan codepoint.

  """
  def unihan_fields do
    @data_dir
    |> Path.join(@unihan_fields_file)
    |> File.read!()
    |> Jason.decode!()
    |> Map.get("records")
    |> Enum.map(fn map ->
      fields = Map.get(map, "fields")
      {name, fields} = Map.pop(fields, "name")

      fields =
        Enum.map(fields, fn
          {"Status", status} ->
            {:status, normalize_atom(status)}

          {"delimiter", "space"} ->
            {:delimiter, "\s"}

          {"delimiter", "N/A"} ->
            {:delimiter, nil}

          {"category", category} ->
            {:category, normalize_atom(category)}

          {"syntax", syntax} when is_binary(syntax) ->
            {:syntax, Regex.compile!(syntax, [:unicode])}

          {field, value} ->
            {String.to_atom(field), value}
        end)
        |> Map.new()

      {String.to_atom(name), fields}
    end)
    |> Map.new()
  end

  @doc """
  Parse the jyutping_index.csv file.

  """
  def parse_cantonese do
    @data_dir
    |> Path.join(@jyutping_index_file)
    |> File.stream!([:trim_bom])
    |> CSV.decode!(headers: true)
    |> Enum.map(fn map ->
      map =
        map
        |> atomize_keys()
        |> Map.put(:final, map["nucleus"] <> map["coda"])

      {map[:jyutping], map}
    end)
    |> Map.new()
  end

  @doc """
  Parse the cjk_radicals.txt file.

  There is one line per CJK radical number. Each line contains three
  fields, separated by a semicolon (';'). The first field is the
  CJK radical number. The second field is the CJK radical character.
  The third field is the CJK unified ideograph.

  Simplified radicals are represented by radical numbers with a
  trailing apostrophe `'`.

  """
  def parse_radicals do
    path = Path.join(data_dir(), @cjk_radicals_file)

    Enum.reduce(File.stream!(path), %{}, fn line, map ->
      case line do
        <<"#", _rest::bitstring>> ->
          map

        <<"\n", _rest::bitstring>> ->
          map

        data ->
          [radical_number, radical_character, unified_ideograph] =
            data
            |> String.split(";", trim: true)
            |> Enum.map(&String.trim/1)

          {radical_number, simplified?} = split_radical_number(radical_number)
          radical_character = String.to_integer(radical_character, 16)
          unified_ideograph = String.to_integer(unified_ideograph, 16)

          radical = radical(radical_number, simplified?, radical_character, unified_ideograph)

          other_radical =
            radical(radical_number, !simplified?, radical_character, unified_ideograph)

          # When no value, assume the current value is for both traditional
          # and simplified. A later entry may overwrite one of them.
          Map.get_and_update(map, radical_number, fn
            nil ->
              {nil, Map.merge(radical, other_radical)}

            current_value when is_map(current_value) ->
              {current_value, Map.merge(current_value, radical)}
          end)
          |> elem(1)
      end
    end)
  end

  defp radical(radical_number, true = _simplified?, radical_character, unified_ideograph) do
    %{Hans: radical(radical_number, radical_character, unified_ideograph)}
  end

  defp radical(radical_number, false = _simplified?, radical_character, unified_ideograph) do
    %{Hant: radical(radical_number, radical_character, unified_ideograph)}
  end

  defp radical(radical_number, radical_character, unified_ideograph) do
    %{
      radical_number: radical_number,
      radical_character: radical_character,
      unified_ideograph: unified_ideograph
    }
  end

  # Simplified radicals are represented by radical numbers with a
  # trailing apostrophe `'`.

  defp split_radical_number(number) do
    case String.split(number, "'") do
      [number] -> {String.to_integer(number), false}
      [number, _prime] -> {String.to_integer(number), true}
    end
  end

  defp decode_metadata(key, value, fields) do
    key = String.to_atom(key)

    value =
      key
      |> maybe_split_value(value, fields)
      |> decode_value(key, fields)

    {key, value}
  end

  defp maybe_unwrap([value]), do: value
  defp maybe_unwrap(value), do: value

  defp maybe_split_value(key, value, fields) do
    field = Map.fetch!(fields, key)

    case field.delimiter do
      nil -> value
      delimiter -> String.split(value, delimiter)
    end
  end

  # Values where decoding depends on the number of items
  # in the value list go here - before the clause
  # that maps over a list of values individually.

  defp decode_value(value, :kTotalStrokes, _fields) do
    case Enum.map(value, &String.to_integer/1) do
      [zh] -> %{Hans: zh, Hant: zh}
      [hans, hant] -> %{Hans: hans, Hant: hant}
    end
  end

  # When its a list, map each value to decode it.
  # Most decode_value clauses should go below this one.
  # Whenever the list contains only one member, we unwrap the list
  # for easier access

  defp decode_value(value, key, fields) when is_list(value) do
    value
    |> Enum.map(&decode_value(&1, key, fields))
    |> maybe_unwrap()
  end

  defp decode_value(value, :kAccountingNumeric, _fields) do
    String.to_integer(value)
  end

  # TODO: this is a bit messy
  defp decode_value(value, :kAlternateTotalStrokes, _fields) do
    value
  end

  defp decode_value(value, :kBigFive, _fields) do
    String.to_integer(value, 16)
  end

  defp decode_value(value, :kCangjie, _fields) do
    String.graphemes(value)
  end

  defp decode_value(value, :kCantonese, _fields) do
    Cantonese.to_jyutping!(value)
  end

  defp decode_value(value, :kCCCII, _fields) do
    value
  end

  defp decode_value(value, :kCheungBauer, _fields) do
    ~r|(?<radical>[0-9]{3})\/(?<stroke>[0-9]{2});(?<cangjie>[A-Z]*);(?<jyutpings>[a-z1-6\[\]\/,]+)|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kCheungBauerIndex, _fields) do
    ~r|(?<page>[0-9]{3})\.(?<position>[01][0-9])|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kCihaiT, _fields) do
    ~r|(?<page>[1-9][0-9]{0,3})\.(?<row>[0-9])(?<position>[0-9]{2})|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kCNS1986, _fields) do
    value
  end

  defp decode_value(value, :kCNS1992, _fields) do
    value
  end

  defp decode_value(value, :kCompatibilityVariant, _fields) do
    decode_codepoint(value)
  end

  defp decode_value(value, :kCowles, _fields) do
    # The fractional value is dropped
    {index, _fraction} = Integer.parse(value)
    index
  end

  defp decode_value(value, :kDaeJaweon, _fields) do
    ~r|(?<page>[0-9]{4})\.(?<position>[0-9]{2})(?<virtual>[01])|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kDefinition, _fields) do
    String.split(value, ";")
  end

  defp decode_value(value, :kEACC, _fields) do
    String.to_integer(value, 16)
  end

  defp decode_value(value, :kFenn, _fields) do
    ~r|(?<fenn_phonetic>[0-9]+)a?(?<importance>[A-KP*])|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kFennIndex, _fields) do
    ~r|(?<page>[0-9][0-9]{0,2})\.(?<position>[01][0-9])|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  # despite decimal-looking, this is not a numerical index
  defp decode_value(value, :kFourCornerCode, _fields) do
    codes =
      value
      |> String.graphemes()
      |> Enum.reject(&(&1 == "."))
      |> Enum.map(&String.to_integer/1)

    [:upper_left, :upper_right, :lower_left, :lower_right, :center]
    |> Enum.zip(codes)
    |> Map.new()
  end

  defp decode_value(value, :kFrequency, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kGB0, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kGB1, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kGB3, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kGB5, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kGB7, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kGB8, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kGradeLevel, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kGSR, _fields) do
    ~r|(?<index>[0-9]{4})(?<letter>[a-vx-z])(?<prime>\'?)|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kHangul, _fields) do
    case String.split(value, ":", trim: true) do
      [grapheme] -> %{grapheme: grapheme, source: nil}
      [grapheme, source] -> %{grapheme: grapheme, source: source}
    end
  end

  defp decode_value(value, :kHanYu, _fields) do
    ~r|(?<volume>[1-8])(?<page>[0-9]{4})\.(?<position>[0-3][0-9])(?<virtual>[0-3])|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kHanyuPinlu, _fields) do
    ~r|(?<reading>\S+)\((?<frequency>[0-9]+)\)|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kHanyuPinyin, _fields) do
    [locations, readings] = String.split(value, ":")

    locations =
      locations
      |> String.split(",")
      |> Enum.map(fn location ->
        ~r|(?<page>[1-8][0-9]{4})\.(?<position>[0-3][0-9])(?<virtual>[0-3])|
        |> Regex.named_captures(location)
        |> decode_captures()
      end)

    readings =
      readings
      |> String.split(",")

    %{
      location: locations,
      readings: readings
    }
  end

  defp decode_value(value, :kHDZRadBreak, _fields) do
    # don't really understand what this field is for?  JC 2023-05
    ~r|\S+\[(?<hex_codepoint>U\+2F[0-9A-D][0-9A-F])\]:(?<volume>[1-8])(?<page>[0-9]{4})\.(?<position>[0-3][0-9])(?<virtual>0)|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kHKGlyph, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kHKSCS, _fields) do
    String.to_integer(value, 16)
  end

  defp decode_value(value, :kIBMJapan, _fields) do
    String.to_integer(value, 16)
  end

  defp decode_value(value, :kIICore, _fields) do
    [priority | irg] = String.graphemes(value)
    %{
      priority: priority,
      irg:      irg
    }
  end

  defp decode_value(value, :kIRG_GSource, _fields) do
    [source | mapping] = String.split(value, "-")
    %{source: source, mapping: mapping}
  end

  defp decode_value(value, :kIRG_HSource, _fields) do
    [source, mapping] = String.split(value, "-")
    %{source: source, mapping: mapping}
  end

  defp decode_value(value, :kIRG_JSource, _fields) do
    [source, mapping] = String.split(value, "-")
    %{source: source, mapping: mapping}
  end

  defp decode_value(value, :kIRG_KPSource, _fields) do
    [source, mapping] = String.split(value, "-")
    %{source: source, mapping: mapping}
  end

  defp decode_value(value, :kIRG_KSource, _fields) do
    [source, mapping] = String.split(value, "-")
    %{source: source, mapping: mapping}
  end

  defp decode_value(value, :kIRG_MSource, _fields) do
    [source, mapping] = String.split(value, "-")
    %{source: source, mapping: mapping}
  end

  defp decode_value(value, :kIRG_SSource, _fields) do
    [source, mapping] = String.split(value, "-")
    %{source: source, mapping: mapping}
  end

  defp decode_value(value, :kIRG_TSource, _fields) do
    [source, mapping] = String.split(value, "-")
    %{source: source, mapping: mapping}
  end

  defp decode_value(value, :kIRG_UKSource, _fields) do
    [source, mapping] = String.split(value, "-")
    %{source: source, mapping: mapping}
  end

  defp decode_value(value, :kIRG_USource, _fields) do
    [source, mapping] = String.split(value, "-")
    %{source: source, mapping: mapping}
  end

  defp decode_value(value, :kIRG_VSource, _fields) do
    [source, mapping] = String.split(value, "-")
    %{source: source, mapping: mapping}
  end

  defp decode_value(value, :kIRGDaeJaweon, _fields) do
    ~r|(?<page>[0-9]{4})\.(?<position>[0-9]{2})(?<virtual>[01])|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kIRGDaiKanwaZiten, _fields) do
    ~r|(?<index>[0-9]{5})(?<prime>\'?)|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kIRGHanyuDaZidian, _fields) do
    ~r|(?<volume>[1-8])(?<page>[0-9]{4})\.(?<position>[0-3][0-9])(?<virtual>[01])|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kIRGKangXi, _fields) do
    ~r|(?<page>[0-9]{4})\.(?<position>[0-9]{2})(?<virtual>[01])|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kJa, _fields) do
    value
  end

  defp decode_value(value, :kJapaneseKun, _fields) do
    value
  end

  defp decode_value(value, :kJapaneseOn, _fields) do
    value
  end

  defp decode_value(value, :kJinmeiyoKanji, _fields) do
    [year | codepoint] = String.split(value, ":")
    case codepoint do
      [] -> %{year: String.to_integer(year)}
      _  ->
        %{
          year: String.to_integer(year),
          codepoint: codepoint |> Enum.at(0) |> decode_codepoint()
        }
    end
  end

  defp decode_value(value, :kJis0, _fields) do
    value
  end

  defp decode_value(value, :kJis1, _fields) do
    value
  end

  defp decode_value(value, :kJIS0213, _fields) do
    value
  end

  defp decode_value("U+"<>codepoint, :kJoyoKanji, _fields) do
    %{codepoint: String.to_integer(codepoint, 16)}
  end

  defp decode_value(year, :kJoyoKanji, _fields) do
    %{year: String.to_integer(year)}
  end

  defp decode_value(value, :kKangXi, _fields) do
    ~r|(?<page>[0-9]{4})\.(?<position>[0-9]{2})(?<virtual>[01])|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kKarlgren, _fields) do
    {index, trail} = Integer.parse(value)
    %{index: index, trail: trail}
  end

  defp decode_value(value, :kKorean, _fields) do
    value
  end

  defp decode_value(value, :kKoreanEducationHanja, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kKoreanName, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kKPS0, _fields) do
    value
  end

  defp decode_value(value, :kKPS1, _fields) do
    value
  end

  defp decode_value(value, :kKSC0, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kKSC1, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kLau, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kMainlandTelegraph, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kMandarin, _fields) do
    value
  end

  defp decode_value(value, :kMatthews, _fields) do
    # not clear what trailing a or 0.5 represents
    {index, trail} = Integer.parse(value)
    %{
      index:    index,
      trailing: trail
    }
  end

  defp decode_value(value, :kMeyerWempe, _fields) do
    # not clear what "subsidiary letters" represent
    ~r|(?<index>[1-9][0-9]{0,3})(?<letter>[a-t*]?)|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kMorohashi, _fields) do
    ~r|(?<index>[0-9]{5})(?<prime>\'?)|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kNelson, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kOtherNumeric, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kPhonetic, _fields) do
    {class, trail} = Integer.parse(value)
    case trail do
      ""  -> %{class: class}
      "*" -> %{class: class, implicit: true}
      "x" -> %{class: class, error: true}
      _ -> %{class: class, subsidiary: trail}
    end
  end

  defp decode_value(value, :kPrimaryNumeric, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kPseudoGB1, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kRSAdobe_Japan1_6, _fields) do
    ~r|(?<code>[CV])\+(?<cid>[0-9]{1,5})\+(?<kangxi>[1-9][0-9]{0,2})\.(?<strokes_radical>[1-9][0-9]?)\.(?<strokes_residue>[0-9]{1,2})|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kRSKangXi, _fields) do
    ~r|(?<radical>[1-9][0-9]{0,2})\.(?<strokes>-?[0-9]{1,2})|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kRSUnicode, _fields) do
    ~r|(?<radical>[1-9][0-9]{0,2})(?<simplified_radical>\'?)\.(?<strokes>-?[0-9]{1,2})|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kSBGY, _fields) do
    ~r|(?<page>[0-9]{3})\.(?<position>[0-7][0-9])|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kSemanticVariant, _fields) do
    list = String.split(value, "<")
    codepoint = Enum.at(list, 0) |> decode_codepoint()
    sources   = Enum.at(list, 1)

    # This does not split the source by its trailing : descriptor
    case sources do
      nil -> %{codepoint: codepoint}
      _   -> %{
                codepoint:  codepoint,
                sources:    sources
                            |> String.split(",")
              }
    end
  end

  defp decode_value(value, :kSimplifiedVariant, _fields) do
    decode_codepoint(value)
  end

  defp decode_value(value, :kSpecializedSemanticVariant, _fields) do
    list = String.split(value, "<")
    codepoint = Enum.at(list, 0) |> decode_codepoint()
    sources   = Enum.at(list, 1)

    case sources do
      nil -> %{codepoint: codepoint}
      _   -> %{
                codepoint:  codepoint,
                sources:    sources
                            |> String.split(",")
              }
    end
  end

  defp decode_value(value, :kSpoofingVariant, _fields) do
    decode_codepoint(value)
  end

  defp decode_value("A", :kStrange, _fields) do
    %{category: :asymmetric}
  end

  defp decode_value("C", :kStrange, _fields) do
    %{category: :cursive}
  end

  defp decode_value("U", :kStrange, _fields) do
    %{category: :unusual}
  end

  defp decode_value("B:"<>value, :kStrange, _fields) do
    %{category: :bopomofo, codepoint: decode_codepoint(value)}
  end

  defp decode_value("H:"<>value, :kStrange, _fields) do
    %{category: :hangul, codepoint: decode_codepoint(value)}
  end

  defp decode_value("S:"<>value, :kStrange, _fields) do
    %{category: :stroke_heavy, strokes: String.to_integer(value)}
  end

  defp decode_value(value, :kStrange, _fields) do
    [category | unicode] = String.split(value, ":")
    category =
      case category do
        "F" -> :fully_reflective
        "M" -> :mirrored
        "O" -> :odd
        "R" -> :rotated
        "I" -> :incomplete
        "K" -> :katakana
      end

    codepoints = Enum.map(unicode, &decode_codepoint/1)
    if codepoints == [] do
      %{category: category}
    else
      %{category: category, codepoints: codepoints}
    end
  end

  defp decode_value(value, :kTaiwanTelegraph, _fields) do
    String.to_integer(value)
  end

  defp decode_value(value, :kTang, _fields) do
    ~r|(?<frequent>\*?)(?<reading>\S+)|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kTGH, _fields) do
    ~r|(?<year>20[0-9]{2}):(?<index>[1-9][0-9]{0,3})|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kTGHZ2013, _fields) do
    value
  end

  defp decode_value(value, :kTraditionalVariant, _fields) do
    decode_codepoint(value)
  end

  defp decode_value(value, :kUnihanCore2020, _fields) do
    String.graphemes(value)
  end

  defp decode_value(value, :kVietnamese, _fields) do
    value
  end

  defp decode_value(value, :kXerox, _fields) do
    value
  end

  defp decode_value(value, :kXHC1983, _fields) do
    ~r|(?<page>[0-9]{4})\.(?<position>[0-9]{2})(?<entry>[0-9])\*?(,[0-9]{4}\.[0-9]{3}\*?)*:(?<reading>\S+)|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  defp decode_value(value, :kZVariant, _fields) do
    # TODO: properly capture source (section after <)
    ~r|(?<hex_codepoint>U\+[23]?[0-9A-F]{4})(<[ks][A-Za-z0-9_]+(:[TBZ]+)?(,[ks][A-Za-z0-9_]+(:[TBZ]+)?)*)?|
    |> Regex.named_captures(value)
    |> decode_captures()
  end

  # The default decoding is to do nothing.

  defp decode_value(value, _key, _fields) do
    value
  end

  # Decodes a standard `U+xxxx` codepoint into
  # its integer form.

  defp decode_codepoint("U+" <> codepoint) do
    String.to_integer(codepoint, 16)
  end

  defp normalize_atom(category) do
    category
    |> String.downcase()
    |> String.replace(" ", "_")
    |> String.to_atom()
  end

  # Convert captures to atom keys and
  # decoded value (by default try to convert
  # the value to an integer)

  defp decode_captures(map) do
    map
    |> Enum.map(&decode_capture/1)
    |> Map.new()
  end

  defp decode_capture({"virtual", "0"}) do
    {:virtual, false}
  end

  defp decode_capture({"virtual", "1"}) do
    {:virtual, true}
  end

  defp decode_capture({"frequent", ""}) do
    {:frequent, false}
  end

  defp decode_capture({"frequent", "*"}) do
    {:frequent, true}
  end

  defp decode_capture({"simplified_radical", "'"}) do
    {:simplified_radical, true}
  end

  defp decode_capture({"simplified_radical", ""}) do
    {:simplified_radical, false}
  end

  defp decode_capture({"hex_codepoint", value}) do
    {:codepoint, decode_codepoint(value)}
  end

  defp decode_capture({"jyutpings", value}) do
    jyutpings =
      value
      |> String.split(",")
      |> Enum.map(fn jyutping ->
        case Cantonese.to_jyutping(jyutping) do
          {:ok, jyutping_map} -> jyutping_map
          _other -> jyutping
        end
      end)

    {:jyutpings, jyutpings}
  end

  defp decode_capture({key, value}) do
    key = String.to_atom(key)

    value =
      case Integer.parse(value) do
        {integer, ""} -> integer
        _other -> value
      end

    {key, value}
  end

  defp atomize_keys(map) do
    map
    |> Enum.map(fn {key, value} -> {String.to_atom(key), value} end)
    |> Map.new()
  end
end
