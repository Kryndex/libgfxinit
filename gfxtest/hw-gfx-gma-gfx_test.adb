with Ada.Unchecked_Conversion;
with Ada.Command_Line;
with Interfaces.C;

with HW.Time;
with HW.Debug;
with HW.PCI.Dev;
with HW.MMIO_Range;
with HW.GFX.GMA;
with HW.GFX.GMA.Config;
with HW.GFX.GMA.Display_Probing;

package body HW.GFX.GMA.GFX_Test
is
   pragma Disable_Atomic_Synchronization;

   package Dev is new PCI.Dev (PCI.Address'(0, 2, 0));

   type GTT_PTE_Type is mod 2 ** (Config.GTT_PTE_Size * 8);
   type GTT_Registers_Type is array (GTT_Range) of GTT_PTE_Type;
   package GTT is new MMIO_Range
     (Base_Addr   => 0,
      Element_T   => GTT_PTE_Type,
      Index_T     => GTT_Range,
      Array_T     => GTT_Registers_Type);

   GTT_Backup : GTT_Registers_Type;

   procedure Backup_GTT
   is
   begin
      for Idx in GTT_Range loop
         GTT.Read (GTT_Backup (Idx), Idx);
      end loop;
   end Backup_GTT;

   procedure Restore_GTT
   is
   begin
      for Idx in GTT_Range loop
         GTT.Write (Idx, GTT_Backup (Idx));
      end loop;
   end Restore_GTT;

   type Pixel_Type is record
      Red   : Byte;
      Green : Byte;
      Blue  : Byte;
      Alpha : Byte;
   end record;

   for Pixel_Type use record
      Blue  at 0 range 0 .. 7;
      Green at 1 range 0 .. 7;
      Red   at 2 range 0 .. 7;
      Alpha at 3 range 0 .. 7;
   end record;

   White : constant Pixel_Type := (255, 255, 255, 255);
   Black : constant Pixel_Type := (  0,   0,   0, 255);
   Red   : constant Pixel_Type := (255,   0,   0, 255);
   Green : constant Pixel_Type := (  0, 255,   0, 255);
   Blue  : constant Pixel_Type := (  0,   0, 255, 255);

   function Pixel_To_Word (P : Pixel_Type) return Word32
   with
      SPARK_Mode => Off
   is
      function To_Word is new Ada.Unchecked_Conversion (Pixel_Type, Word32);
   begin
      return To_Word (P);
   end Pixel_To_Word;

   Max_W    : constant := 4096;
   Max_H    : constant := 2160;
   FB_Align : constant := 16#0004_0000#;
   subtype Screen_Index is Natural range
      0 .. 3 * (Max_W * Max_H + FB_Align / 4) - 1;
   type Screen_Type is array (Screen_Index) of Word32;

   package Screen is new MMIO_Range (0, Word32, Screen_Index, Screen_Type);

   Screen_Backup : Screen_Type;

   procedure Backup_Screen (FB : Framebuffer_Type)
   is
      First : constant Screen_Index := Natural (FB.Offset) / 4;
      Last  : constant Screen_Index := First + Natural (FB_Size (FB)) / 4 - 1;
   begin
      for Idx in Screen_Index range First .. Last loop
         Screen.Read (Screen_Backup (Idx), Idx);
      end loop;
   end Backup_Screen;

   procedure Restore_Screen (FB : Framebuffer_Type)
   is
      First : constant Screen_Index := Natural (FB.Offset) / 4;
      Last  : constant Screen_Index := First + Natural (FB_Size (FB)) / 4 - 1;
   begin
      for Idx in Screen_Index range First .. Last loop
         Screen.Write (Idx, Screen_Backup (Idx));
      end loop;
   end Restore_Screen;

   function Corner_Fill
     (X, Y  : Natural;
      FB    : Framebuffer_Type;
      Pipe  : Pipe_Index)
      return Pixel_Type
   is
      Xrel : constant Integer :=
        (if X < 32 then X else X - (Natural (FB.Width) - 32));
      Yrel : constant Integer :=
        (if Y < 32 then Y else Y - (Natural (FB.Height) - 32));

      function Color (Idx : Natural) return Pixel_Type is
        (case (Idx + Pipe_Index'Pos (Pipe)) mod 4 is
            when 0 => Blue,   when      1 => Black,
            when 3 => Green,  when others => Red);
   begin
      return
        (if Xrel mod 16 = 0 or Xrel = 31 or Yrel mod 16 = 0 or Yrel = 31 then
            White
         elsif Yrel < 16 then
           (if Xrel < 16 then Color (0) else Color (1))
         else
           (if Xrel < 16 then Color (3) else Color (2)));
   end Corner_Fill;

   function Fill
     (X, Y        : Natural;
      Framebuffer : Framebuffer_Type;
      Pipe        : Pipe_Index)
      return Pixel_Type
   is
      use type HW.Byte;

      Xp : constant Natural := X * 256 / Natural (Framebuffer.Width);
      Yp : constant Natural := Y * 256 / Natural (Framebuffer.Height);
      Xn : constant Natural := 255 - Xp;
      Yn : constant Natural := 255 - Yp;

      function Map (X, Y : Natural) return Byte is
      begin
         return Byte (X * Y / 255);
      end Map;
   begin
      return
        (case Pipe is
         when GMA.Primary   => (Map (Xn, Yn), Map (Xp, Yn), Map (Xp, Yp), 255),
         when GMA.Secondary => (Map (Xn, Yp), Map (Xn, Yn), Map (Xp, Yn), 255),
         when GMA.Tertiary  => (Map (Xp, Yp), Map (Xn, Yp), Map (Xn, Yn), 255));
   end Fill;

   procedure Test_Screen
     (Framebuffer : Framebuffer_Type;
      Pipe        : GMA.Pipe_Index)
   is
      P        : Pixel_Type;
      -- We have pixel offset wheras the framebuffer has a byte offset
      Offset_Y : Natural := Natural (Framebuffer.Offset / 4);
      Offset   : Natural;

      function Top_Test (X, Y : Natural) return Boolean
      is
         C     : constant Natural := Natural (Framebuffer.Width) / 2;
         S_Y   : constant Natural := 3 * Y / 2;
         Left  : constant Integer := X - C + S_Y;
         Right : constant Integer := X - C - S_Y;
      begin
         return
            Y < 12 and
            ((-1 <= Left and Left <= 0) or
             (0 <= Right and Right <= 1));
      end Top_Test;
   begin
      for Y in 0 .. Natural (Framebuffer.Height) - 1 loop
         Offset := Offset_Y;
         for X in 0 .. Natural (Framebuffer.Width) - 1 loop
            if (X < 32 or X >= Natural (Framebuffer.Width) - 32) and
               (Y < 32 or Y >= Natural (Framebuffer.Height) - 32)
            then
               P := Corner_Fill (X, Y, Framebuffer, Pipe);
            elsif Framebuffer.Rotation /= No_Rotation and then
                  Top_Test (X, Y)
            then
               P := White;
            elsif Y mod 16 = 0 or X mod 16 = 0 then
               P := Black;
            else
               P := Fill (X, Y, Framebuffer, Pipe);
            end if;
            Screen.Write (Offset, Pixel_To_Word (P));
            Offset := Offset + 1;
         end loop;
         Offset_Y := Offset_Y + Natural (Framebuffer.Stride);
      end loop;
   end Test_Screen;

   procedure Calc_Framebuffer
     (FB       :    out Framebuffer_Type;
      Mode     : in     Mode_Type;
      Rotation : in     Rotation_Type;
      Offset   : in out Word32)
   is
   begin
      Offset := (Offset + FB_Align - 1) and not (FB_Align - 1);
      if Rotation = Rotated_90 or Rotation = Rotated_270 then
         FB :=
           (Width    => Width_Type (Mode.V_Visible),
            Height   => Height_Type (Mode.H_Visible),
            BPC      => 8,
            Stride   => Div_Round_Up (Pos32 (Mode.V_Visible), 32) * 32,
            V_Stride => Div_Round_Up (Pos32 (Mode.H_Visible), 32) * 32,
            Tiling   => Y_Tiled,
            Rotation => Rotation,
            Offset   => Offset);
      else
         FB :=
           (Width    => Width_Type (Mode.H_Visible),
            Height   => Width_Type (Mode.V_Visible),
            BPC      => 8,
            Stride   => Div_Round_Up (Pos32 (Mode.H_Visible), 16) * 16,
            V_Stride => Height_Type (Mode.V_Visible),
            Tiling   => Linear,
            Rotation => Rotation,
            Offset   => Offset);
      end if;
      Offset := Offset + Word32 (FB_Size (FB));
   end Calc_Framebuffer;

   Pipes : GMA.Pipe_Configs;

   procedure Prepare_Configs (Rotation : Rotation_Type)
   is
      use type HW.GFX.GMA.Port_Type;

      Offset : Word32 := 0;
      Success : Boolean;
   begin
      GMA.Display_Probing.Scan_Ports (Pipes);

      for Pipe in GMA.Pipe_Index loop
         if Pipes (Pipe).Port /= GMA.Disabled then
            Calc_Framebuffer
              (FB       => Pipes (Pipe).Framebuffer,
               Mode     => Pipes (Pipe).Mode,
               Rotation => Rotation,
               Offset   => Offset);
            GMA.Setup_Default_FB
              (FB       => Pipes (Pipe).Framebuffer,
               Clear    => False,
               Success  => Success);
            if not Success then
               Pipes (Pipe).Port := GMA.Disabled;
            end if;
         end if;
      end loop;

      GMA.Dump_Configs (Pipes);
   end Prepare_Configs;

   procedure Print_Usage
   is
   begin
      Debug.Put_Line
        ("Usage: " & Ada.Command_Line.Command_Name &
         " <delay seconds>" &
         " [(0|90|180|270)]");
      Debug.New_Line;
   end Print_Usage;

   procedure Main
   is
      use type HW.GFX.GMA.Port_Type;
      use type HW.Word64;
      use type Interfaces.C.int;

      Res_Addr : Word64;

      Delay_S : Natural;
      Rotation : Rotation_Type := No_Rotation;

      Dev_Init,
      Initialized : Boolean;

      function iopl (level : Interfaces.C.int) return Interfaces.C.int;
      pragma Import (C, iopl, "iopl");
   begin
      if Ada.Command_Line.Argument_Count < 1 then
         Print_Usage;
         return;
      end if;

      Delay_S := Natural'Value (Ada.Command_Line.Argument (1));

      if Ada.Command_Line.Argument_Count >= 2 then
         declare
            Rotation_Degree : constant String := Ada.Command_Line.Argument (2);
         begin
            if    Rotation_Degree =   "0" then Rotation := No_Rotation;
            elsif Rotation_Degree =  "90" then Rotation := Rotated_90;
            elsif Rotation_Degree = "180" then Rotation := Rotated_180;
            elsif Rotation_Degree = "270" then Rotation := Rotated_270;
            else  Print_Usage; return; end if;
         end;
      end if;

      if iopl (3) /= 0 then
         Debug.Put_Line ("Failed to change i/o privilege level.");
         return;
      end if;

      Dev.Initialize (Dev_Init);
      if not Dev_Init then
         Debug.Put_Line ("Failed to map PCI config.");
         return;
      end if;

      Dev.Map (Res_Addr, PCI.Res0, Offset => Config.GTT_Offset);
      if Res_Addr = 0 then
         Debug.Put_Line ("Failed to map PCI resource0.");
         return;
      end if;
      GTT.Set_Base_Address (Res_Addr);

      Dev.Map (Res_Addr, PCI.Res2, WC => True);
      if Res_Addr = 0 then
         Debug.Put_Line ("Failed to map PCI resource2.");
         return;
      end if;
      Screen.Set_Base_Address (Res_Addr);

      GMA.Initialize
        (Clean_State => True,
         Success     => Initialized);

      if Initialized then
         Backup_GTT;

         Prepare_Configs (Rotation);

         GMA.Update_Outputs (Pipes);

         for Pipe in GMA.Pipe_Index loop
            if Pipes (Pipe).Port /= GMA.Disabled then
               Backup_Screen (Pipes (Pipe).Framebuffer);
               Test_Screen
                 (Framebuffer => Pipes (Pipe).Framebuffer,
                  Pipe        => Pipe);
            end if;
         end loop;

         Time.M_Delay (Delay_S * 1_000);

         for Pipe in GMA.Pipe_Index loop
            if Pipes (Pipe).Port /= GMA.Disabled then
               Restore_Screen (Pipes (Pipe).Framebuffer);
            end if;
         end loop;
         Restore_GTT;
      end if;
   end Main;

end HW.GFX.GMA.GFX_Test;
