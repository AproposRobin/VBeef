using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// Project Browser additions in UE's style: a filter bar (asset kinds, unsaved, recently
	/// changed) and drag-and-drop of tiles onto folders (tiles or the folder tree) to move them.
	extension EditorApp
	{
		/// Bit per AssetKind; 0 = no kind filter.
		int32 mCBFilterMask;
		bool mCBFilterUnsaved;
		bool mCBFilterRecent;
		CBItem mCBDragItem ~ delete _;
		CBItem mCBDropItem ~ delete _;
		String mCBDropFolder = new .() ~ delete _;

		static AssetKind[7] sFilterKinds = .(.Class, .Library, .Struct, .Enum, .Interface, .Globals, .File);

		bool CBFilterActive => mCBFilterMask != 0 || mCBFilterUnsaved || mCBFilterRecent;

		/// Filter button + removable chips for the active filters.
		void DrawCBFilterBar()
		{
			Gui.igPushStyleColor_U32(Col.Button, CBFilterActive ? Theme.Mix(Look.Dropdown, Look.Primary, 0.45f) : Look.Dropdown);
			if (Gui.Button(scope $"{Icon.Filter}  Filters"))
				Gui.OpenPopup("##cbfilters");
			Gui.igPopStyleColor(1);
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("Show only some kinds of assets");
			if (Gui.BeginPopup("##cbfilters"))
			{
				Gui.TextDisabled("Asset Kinds");
				for (let k in sFilterKinds)
				{
					int32 bit = 1 << (int32)k;
					bool on = (mCBFilterMask & bit) != 0;
					Gui.igPushStyleColor_U32(ColX.CheckMark, AssetStyle.KindColor(k));
					if (Gui.Checkbox(AssetStyle.KindLabel(k), &on))
						mCBFilterMask = on ? (mCBFilterMask | bit) : (mCBFilterMask & ~bit);
					Gui.igPopStyleColor(1);
				}
				Gui.Separator();
				Gui.TextDisabled("Other");
				Gui.Checkbox("Unsaved", &mCBFilterUnsaved);
				Gui.Checkbox("Changed in the last 24 hours", &mCBFilterRecent);
				Gui.Separator();
				if (Gui.MenuItem("Reset Filters", "", false, CBFilterActive))
				{
					mCBFilterMask = 0;
					mCBFilterUnsaved = false;
					mCBFilterRecent = false;
				}
				Gui.EndPopup();
			}
			// Active filter chips (click to remove), like UE's filter bar.
			for (let k in sFilterKinds)
			{
				int32 bit = 1 << (int32)k;
				if ((mCBFilterMask & bit) == 0)
					continue;
				Gui.SameLine(0, 4);
				if (FilterChip(AssetStyle.KindLabel(k), AssetStyle.KindColor(k)))
					mCBFilterMask &= ~bit;
			}
			if (mCBFilterUnsaved)
			{
				Gui.SameLine(0, 4);
				if (FilterChip("Unsaved", Look.Warning))
					mCBFilterUnsaved = false;
			}
			if (mCBFilterRecent)
			{
				Gui.SameLine(0, 4);
				if (FilterChip("Recent", Look.AccentBlue))
					mCBFilterRecent = false;
			}
		}

		static bool FilterChip(StringView label, uint32 color)
		{
			Gui.igPushStyleColor_U32(Col.Button, Theme.Mix(Look.Recessed, color, 0.3f));
			Gui.igPushStyleColor_U32(Col.ButtonHovered, Theme.Mix(Look.Recessed, color, 0.5f));
			Gui.igPushStyleColor_U32(Col.Border, color);
			bool clicked = Gui.Button(scope $"{label}  {Icon.X}");
			Gui.igPopStyleColor(3);
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("Remove this filter");
			return clicked;
		}

		/// Drops items the filters exclude (folders always stay so navigation keeps working).
		void FilterCBItems(List<CBItem> items)
		{
			if (!CBFilterActive)
				return;
			let now = DateTime.Now;
			for (int i = items.Count - 1; i >= 0; i--)
			{
				let it = items[i];
				if (it.Kind == .Folder)
					continue;
				bool keep = true;
				if (mCBFilterMask != 0 && (mCBFilterMask & (1 << (int32)it.Kind)) == 0)
					keep = false;
				if (keep && mCBFilterUnsaved && !it.Modified)
					keep = false;
				if (keep && mCBFilterRecent)
				{
					keep = false;
					if (File.GetLastWriteTime(it.Path) case .Ok(let t))
						keep = (now - t).TotalHours < 24;
				}
				if (!keep)
				{
					delete it;
					items.RemoveAt(i);
				}
			}
		}

		// ---------------------------------------------------------------- drag to move

		/// Call right after a tile's item: makes it draggable, and folders accept drops.
		void CBTileDragDrop(CBItem item)
		{
			if (Gui.igBeginDragDropSource(0))
			{
				if (mCBDragItem == null || mCBDragItem.Key != item.Key)
				{
					delete mCBDragItem;
					mCBDragItem = item.Clone();
				}
				int32 dummy = 1;
				Gui.igSetDragDropPayload("VB_CBITEM", &dummy, sizeof(int32), 0);
				Gui.Text(scope $"{Icon.Move}  Move {item.Name}");
				Gui.TextDisabled("Drop on a folder (tile or tree)");
				Gui.igEndDragDropSource();
			}
			if (item.Kind == .Folder)
				CBFolderDropTarget(item.Path);
		}

		/// Call right after a folder item (tile or tree node).
		void CBFolderDropTarget(StringView folder)
		{
			if (!Gui.igBeginDragDropTarget())
				return;
			let payload = Gui.igAcceptDragDropPayload("VB_CBITEM", 0);
			if (payload != null && mCBDragItem != null)
			{
				// Applied after the grid is drawn (the move rescans the project).
				delete mCBDropItem;
				mCBDropItem = mCBDragItem.Clone();
				mCBDropFolder.Set(folder);
			}
			Gui.igEndDragDropTarget();
		}

		/// Performs a pending drop (call outside any iteration of the index).
		void ProcessCBDrop()
		{
			if (mCBDropItem == null)
				return;
			let item = mCBDropItem;
			mCBDropItem = null;
			defer delete item;
			String folder = scope .(mCBDropFolder);
			mCBDropFolder.Clear();
			MoveAssetToFolder(item, folder);
		}

		/// Moves a folder, a file, or a type that owns its file into `folder` through the safe
		/// rename path (AssetOps.MovePath: never overwrites, takes the .vblayout side file along;
		/// then open documents are remapped and the project rescanned). Refused in a read-only
		/// project. Namespaces are not rewritten.
		public void MoveAssetToFolder(CBItem item, StringView folder)
		{
			if (!CheckWritable())
				return;
			String parent = scope .();
			Path.GetDirectoryPath(item.Path, parent).IgnoreError(); // a root has no parent: parent stays empty, compares unequal below
			if (ProjectIndex.SamePath(parent, folder))
				return;
			bool isFolder = item.Kind == .Folder;
			if (isFolder && (ProjectIndex.SamePath(item.Path, folder) || IsUnder(folder, item.Path)))
			{
				Notify.Warn("A folder can't be moved into itself");
				return;
			}
			if (item.IsType && !TypeOwnsFile(item))
			{
				Notify.Warn(scope $"{item.Name} shares its file with other types; move the file instead");
				return;
			}
			String name = scope .();
			Path.GetFileName(item.Path, name);
			String target = scope .();
			JoinPath(folder, name, target);
			if (File.Exists(target) || Directory.Exists(target))
			{
				Notify.Warn(scope $"{name} already exists in that folder");
				return;
			}
			String err = scope .();
			if (AssetOps.MovePath(item.Path, target, isFolder, err) case .Err)
			{
				ReportError(err.IsEmpty ? scope $"Could not move {name} (is it open in another program?)" : err);
				return;
			}
			RemapDocPaths(item.Path, target, isFolder);
			if (isFolder && !WorkspaceAfterFolderMove(item.Path, target))
			{
				String back = scope .();
				if (AssetOps.MovePath(target, item.Path, true, back) case .Ok)
					RemapDocPaths(target, item.Path, true);
				ScanProject();
				return;
			}
			ScanProject();
			SaveSettings();
			String folderName = scope .();
			Path.GetFileName(folder, folderName);
			Notify.Success(scope $"Moved {name} to {folderName}");
		}
	}
}
