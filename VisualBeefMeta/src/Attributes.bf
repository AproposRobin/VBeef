using System;

/// VisualBeefMeta: attributes that tell VisualBeef which members become nodes, and how they look.
///
/// These are ordinary Beef attributes with no runtime cost and no dependencies besides corlib, so
/// code that uses them compiles the same with or without VisualBeef. VisualBeef never needs the
/// compiler to read them: it parses the attribute text straight from the source (and caches it).
///
/// Reference with examples: docs/Node-Attributes.md
namespace VisualBeef
{
	/// Offers a method (or property) as a node.
	///
	/// ```
	/// [Node(Category="Gameplay|Health", DisplayName="Apply Damage", Keywords="hurt hit", Tooltip="Subtracts health.")]
	/// public void ApplyDamage(int amount) { ... }
	/// ```
	[AttributeUsage(.Method | .Property)]
	public struct NodeAttribute : Attribute
	{
		/// Menu path; `|` separates submenus ("Math|Vector"). Default: Namespace|Type.
		public String Category;
		/// Menu and node title. Default: the member name split into words.
		public String DisplayName;
		/// Extra search words, space separated.
		public String Keywords;
		/// Hover text. Default: the `///` doc comment above the member.
		public String Tooltip;
		/// No flow pins (a value call). Same as adding [Pure].
		public bool Pure;
		/// Draw as a compact operator-style node.
		public bool Compact;
		/// Title of the compact node ("+", "|v|"). Default: DisplayName.
		public String CompactTitle;
		/// Listed under "advanced" (hidden unless searched for).
		public bool Advanced;

		public this()
		{
			this = default;
		}

		public this(String category)
		{
			this = default;
			Category = category;
		}
	}

	/// A node without flow pins (a value call). Use it for functions with no side effects.
	///
	/// ```
	/// [Pure] public static float Square(float x) => x * x;
	/// ```
	[AttributeUsage(.Method | .Property)]
	public struct PureAttribute : Attribute
	{
		/// Optional menu path, same as [Node(Category=...)].
		public String Category;

		public this()
		{
			this = default;
		}

		public this(String category)
		{
			Category = category;
		}
	}

	/// Shows a field or property in the variables palette with Get/Set nodes.
	/// ReadOnly offers Get only.
	///
	/// ```
	/// [Expose(Category="Stats", Min=0, Max=100)] public int Health = 100;
	/// [Expose(ReadOnly=true)] public int Kills;
	/// ```
	[AttributeUsage(.Field | .Property)]
	public struct ExposeAttribute : Attribute
	{
		public String Category;
		public String DisplayName;
		public String Tooltip;
		/// Only a Get node is offered.
		public bool ReadOnly;
		/// Slider range in the Details panel (both 0 = no range).
		public double Min;
		public double Max;

		public this()
		{
			this = default;
		}

		public this(String category)
		{
			this = default;
			Category = category;
		}
	}

	/// Per-parameter metadata: the pin's label, hover text and default value.
	///
	/// ```
	/// public static float Lerp(float a, float b, [Pin(Name="Alpha", Tooltip="0..1", Default="0.5f")] float t) ...
	/// ```
	/// A Beef default value (`float t = 0.5f`) already becomes the pin default; Default here is
	/// for the cases where the signature cannot have one.
	[AttributeUsage(.Parameter)]
	public struct PinAttribute : Attribute
	{
		public String Name;
		public String Tooltip;
		public String Default;
		/// Hidden behind the node's "show advanced" arrow.
		public bool Advanced;
		/// On a `ref` parameter: the function only writes it (an Unreal out parameter passed by
		/// reference). The node shows it as an output pin, like an `out` parameter, and the code
		/// passes a fresh variable: `T name = default; Foo(ref name);`.
		public bool Out;

		public this()
		{
			this = default;
		}

		public this(String name)
		{
			this = default;
			Name = name;
		}
	}

	/// Marks a static class whose public static functions all become nodes.
	/// Non-void functions without ref/out parameters default to pure.
	///
	/// ```
	/// [NodeLibrary(Category="Math|Vector")]
	/// public static class VectorLib { public static float Dot(Vector3 a, Vector3 b) => ...; }
	/// ```
	[AttributeUsage(.Class | .Struct)]
	public struct NodeLibraryAttribute : Attribute
	{
		public String Category;

		public this()
		{
			this = default;
		}

		public this(String category)
		{
			Category = category;
		}
	}

	/// Keeps a member (or every member of a type) out of the action menu.
	///
	/// ```
	/// [NodeHidden] public static void InternalThunk() { }
	/// ```
	[AttributeUsage(.Method | .Property | .Field | .Class | .Struct)]
	public struct NodeHiddenAttribute : Attribute
	{
	}

	/// A one-argument function that converts its parameter's type into its return type.
	/// VisualBeef offers it when a wire joins those two types.
	///
	/// ```
	/// [Conversion] public static String ToText(Vector3 v) => ...;
	/// ```
	[AttributeUsage(.Method)]
	public struct ConversionAttribute : Attribute
	{
	}

	/// Turns an enum or Result value into one flow output per case.
	/// Param names the parameter (or "return" for the return value).
	///
	/// ```
	/// [Node, ExpandEnumAsFlow("return")] public Result<int> Parse(StringView s) ...
	/// ```
	[AttributeUsage(.Method)]
	public struct ExpandEnumAsFlowAttribute : Attribute
	{
		public String Param;

		public this(String param)
		{
			Param = param;
		}
	}

	/// The name this attribute had before the vocabulary pass; still accepted, same meaning as
	/// ExpandEnumAsFlow.
	[AttributeUsage(.Method)]
	public struct ExpandEnumAsExecsAttribute : Attribute
	{
		public String Param;

		public this(String param)
		{
			Param = param;
		}
	}

	/// A type that can be used for variables and pins, with Make/Break nodes for structs.
	///
	/// ```
	/// [ExposeType] public struct DamageInfo { public int Amount; public bool Critical; }
	/// ```
	[AttributeUsage(.Class | .Struct | .Enum | .Interface)]
	public struct ExposeTypeAttribute : Attribute
	{
		public bool MakeBreak;

		public this()
		{
			this = default;
		}
	}

	/// The name this attribute had before the vocabulary pass; still accepted, same meaning as
	/// ExposeType.
	[AttributeUsage(.Class | .Struct | .Enum | .Interface)]
	public struct BlueprintTypeAttribute : Attribute
	{
		public bool MakeBreak;

		public this()
		{
			this = default;
		}
	}
}
