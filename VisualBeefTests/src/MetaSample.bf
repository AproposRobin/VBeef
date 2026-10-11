using System;
using VisualBeef;

/// The examples from docs/Node-Attributes.md, compiled as part of the tests so the attribute
/// set is known to build (they're never called).
namespace VisualBeef.Tests.MetaSample
{
	[ExposeType]
	public struct Vector3
	{
		public float X, Y, Z;
	}

	[NodeLibrary(Category="Math|Vector")]
	public static class VectorLib
	{
		/// Length of the vector.
		[Pure, Node(CompactTitle="|v|")]
		public static float Length(Vector3 v) => Math.Sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z);

		[Node("Math|Vector", DisplayName="Lerp (Vector)", Keywords="interpolate blend")]
		public static Vector3 Lerp(Vector3 a, Vector3 b, [Pin(Name="Alpha", Tooltip="0 to 1")] float t = 0.5f)
		{
			return .() { X = a.X + (b.X - a.X) * t, Y = a.Y + (b.Y - a.Y) * t, Z = a.Z + (b.Z - a.Z) * t };
		}

		[Conversion]
		public static String ToText(Vector3 v) => null;

		[NodeHidden]
		public static void InternalThunk() { }
	}

	public enum DamageResult { Blocked, Hit, Killed }

	public class Player
	{
		[Expose(Category="Stats", Min=0, Max=100, Tooltip="Hit points")]
		public int Health = 100;
		[Expose(ReadOnly=true)]
		public int Kills;

		[Node(Category="Gameplay|Health", DisplayName="Apply Damage", Keywords="hurt hit", Tooltip="Subtracts health.")]
		public void ApplyDamage(int amount, [Pin(Default="1")] int times) { Health -= amount * times; }

		[Pure("Gameplay")]
		public bool IsAlive() => Health > 0;

		[Node, ExpandEnumAsFlow("return")]
		public DamageResult TryHit(int amount) => .Hit;

		[Node(Advanced=true, Compact=true, Pure=true)]
		public static int Twice(int x) => x * 2;
	}
}
