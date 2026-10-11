using System;

namespace Debuggee
{
	/// The program the `debug` test runs under the debugger (VisualBeefTests DebugTests.bf).
	/// Line numbers matter to the test only through the graphs, never as constants.
	class Greeter
	{
		public int mCount = 3;

		public int Add(int a, int b)
		{
			int sum = a + b;
			mCount += sum;
			return sum;
		}

		public void Hello(String name)
		{
			Console.WriteLine("Hello {}", name);
			int total = Add(2, 5);
			Console.WriteLine("Total {}", total);
		}
	}

	class Program
	{
		public static int Main(String[] args)
		{
			let g = scope Greeter();
			if (args.Count > 0 && args[0] == "crash")
			{
				Greeter missing = null;
				missing.mCount = 1;
			}
			if (args.Count > 0 && args[0] == "loop")
			{
				// Runs until the debugger pauses and stops it.
				while (g.mCount > 0)
					System.Threading.Thread.Sleep(10);
			}
			g.Hello("Beef");
			Console.WriteLine("Done");
			return 7;
		}
	}
}
