using System;

/// A node library as a host tool ships one (docs/Host-Integration.md > Node libraries): it declares its own node
/// attributes with VisualBeef's names and fields, so it builds without VisualBeefMeta, and marks what the editor
/// offers. Used by `VisualBeefTests host` / `catalog` and by `VB_SELFTEST=host`.
namespace FixtureKit.NodeMeta
{
	[AttributeUsage(.Class | .Struct)]
	public struct NodeLibraryAttribute : Attribute
	{
		public String DisplayName;
		public String Category;

		public this()
		{
			this = default;
		}

		public this(String displayName)
		{
			this = default;
			DisplayName = displayName;
		}
	}

	[AttributeUsage(.Method | .Property)]
	public struct NodeAttribute : Attribute
	{
		public String Category;
		public String DisplayName;
		public String Tooltip;
		public bool Pure;

		public this()
		{
			this = default;
		}
	}

	[AttributeUsage(.Method)]
	public struct CallbackNodeAttribute : Attribute
	{
		public String DisplayName;
		public String Category;
		public String Tooltip;
		public String Role;
		public String Callback;

		public this()
		{
			this = default;
		}

		public this(String displayName)
		{
			this = default;
			DisplayName = displayName;
		}
	}

	[AttributeUsage(.Method | .Property | .Field | .Class | .Struct)]
	public struct NodeHiddenAttribute : Attribute
	{
	}
}

namespace FixtureKit
{
	using FixtureKit.NodeMeta;

	/// A calendar with one replaceable function: the callback shape every host API of this kind has.
	[NodeLibrary("Fixture Kit")]
	public static class Clock
	{
		static function int32(int32) sDaysInYear;

		/// Days in a year (the callback's answer when one is registered).
		public static int32 DaysInYear(int32 year)
		{
			if (sDaysInYear != null)
				return sDaysInYear(year);
			return CallOriginalDaysInYear(year);
		}

		/// Replaces Days In Year with `Callback`.
		[CallbackNode("Register Days In Year", Role="Register")]
		public static Result<void> RegisterDaysInYear(function int32(int32) Callback)
		{
			if (sDaysInYear != null)
				return .Err;
			sDaysInYear = Callback;
			return .Ok;
		}

		[CallbackNode("Try register Days In Year", Tooltip="Registers the callback; false when one is registered already.")]
		public static bool TryRegisterDaysInYear(function int32(int32) Callback)
		{
			return RegisterDaysInYear(Callback) case .Ok;
		}

		[CallbackNode("Remove Days In Year", Role="Remove")]
		public static void RemoveDaysInYear()
		{
			sDaysInYear = null;
		}

		[CallbackNode("Call original Days In Year", Role="Original")]
		public static int32 CallOriginalDaysInYear(int32 year)
		{
			return ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0) ? 366 : 365;
		}

		[NodeHidden]
		public static void SlotTable()
		{
		}
	}

	/// An ordinary attributed type of the same library: only the tagged member is offered.
	public struct Stamp
	{
		public int64 Ticks;

		[Node(Category="Fixture Kit|Time", DisplayName="Stamp Now", Pure=true)]
		public static Stamp Now() => .() { Ticks = 1 };

		public static void Untagged()
		{
		}
	}
}
