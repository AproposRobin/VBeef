using System;
using VisualBeef;

namespace Game.Math
{
	struct Vec3
	{
		public float X, Y, Z;
	}

	/// Vector helpers.
	[NodeLibrary(Category="Math|Vector")]
	static class VectorLib
	{
		/// Dot product of two vectors.
		/// <param name="a">The first vector</param>
		public static float Dot(Vec3 a, Vec3 b) => a.X * b.X + a.Y * b.Y + a.Z * b.Z;

		/// Blends two vectors.
		[Node(Category="Math|Vector", DisplayName="Lerp (Vector)", Keywords="interpolate blend mix")]
		public static Vec3 Lerp(Vec3 a, Vec3 b, [Pin(Name="Alpha", Tooltip="0 to 1")] float t = 0.5f) => a;

		public static void Normalize(ref Vec3 v) { }

		[NodeHidden] public static void InternalThunk() { }

		public static int Clamp(int value, int min, int max) => value;
		public static float Clamp(float value, float min, float max) => value;

		[Conversion] public static String ToText(Vec3 v) => null;

		static float PrivateHelper() => 0;
	}
}

namespace Game
{
	class Actor
	{
	}

	class Player : Actor
	{
		[Expose(Category="Stats", Min=0, Max=100)] public int Health = 100;
		[Expose(ReadOnly=true)] public static int MaxPlayers = 4;
		[Expose] public static int Score;
		public int NotExposed;

		[Node(Category="Gameplay", Tooltip="Hurts the player.")]
		public void TakeDamage(int amount, [Pin(Default="1")] int times) { }

		[Pure] public bool IsAlive() => Health > 0;

		public void Untagged() { }

		[Node, ExpandEnumAsFlow("return")] public Result<int> Parse(StringView s) => .Err;

#if BF_PLATFORM_WINDOWS
		[Node] public void Platform() { }
#else
		[Node] public void Platform() { }
#endif
	}

	[NodeHidden]
	static class Hidden
	{
		[Node] public static void NotShown() { }
	}
}
