using System;
using System.Collections;
using Other;

namespace Other
{
	class Shape
	{
		public int Sides;
	}
}

namespace Plain
{
	interface IDamageable
	{
		void Damage(int amount);
	}

	class Shape : IDamageable
	{
		public float Area;
		public void Damage(int amount) { }
	}

	class Circle : Shape
	{
		public float Radius;
	}

	class Calc
	{
		public static int Add(int a, int b) => a + b;
		public static float Add(float a, float b) => a + b;
		public static int Add(int a, int b, int c) => a + b + c;
		public static double Scale(double v, double factor = 2.0) => v * factor;
		static void Hidden() { }
		internal static void Internal() { }
		public static T Pick<T>(T a, T b) => a;
		public static int Sum(Object o) => 0;
		public static int Sum(params int[] values) => 0;

#if DEBUG
		public this(int seed) { }
		public static void Twice() { }
#else
		public this(int seed) { }
		public static void Twice() { }
#endif

		public static Result<int> Parse(StringView s) => .Ok(1);

		public void Run(StringView s, List<int> list, Shape shape)
		{
			let d = 1.0;
			let f = 1.0f;
			let u = 1u;
			let h = 0xFF;
			let l = 5L;
			let str = $"x{d}";
			let ch = 'c';
			let sum = Add(1, 2);
			let fsum = Add(1.0f, 2.0f);
			let three = Add(1, 2, 3);
			let scaled = Scale(3.0);
			let parsed = Try!(Parse(s));
			list.Add(4);
			let area = shape.Area;
			let pick = Pick(1, 2);
		}

		public Result<int> Run2(StringView s)
		{
			let n = Try!(int.Parse(s));
			let len = s.Length;
			let m = Math.Max(1, 2);
			let mf = Math.Max(1.0f, 2.0f);
			return .Ok(n);
		}
	}
}
