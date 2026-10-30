// Ayudante nativo de vpn.ps1: accesibilidad MSAA de la consola de FortiClient,
// teclado (SendInput Unicode, sin portapapeles) y Administrador de credenciales.
// Regla: la contraseña nunca sale de este fichero como string; se lee del
// Administrador de credenciales y se teclea directamente en el campo.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;
using System.Threading;
using Accessibility;

namespace VpnForti
{
    public class Nodo
    {
        public IAccessible Acc;
        public object Hijo;
        public int Rol;
        public string Nombre;
        public int Estado;
        public int X, Y, W, H;
        public int Profundidad;
        public const int ROL_TEXTO_EDITABLE = 42, ROL_BOTON = 43, ROL_CASILLA = 44, ROL_COMBO = 46, ROL_ESTATICO = 41;
        public const int ESTADO_NO_DISPONIBLE = 0x1, ESTADO_ENFOCADO = 0x4, ESTADO_INVISIBLE = 0x8000, ESTADO_ENFOCABLE = 0x100000, ESTADO_PROTEGIDO = 0x20000000;
        public bool Enfocable { get { return (Estado & ESTADO_ENFOCABLE) != 0; } }
        public bool Protegido { get { return (Estado & ESTADO_PROTEGIDO) != 0; } }
        public bool Enfocado { get { return (Estado & ESTADO_ENFOCADO) != 0; } }
        public bool Invisible { get { return (Estado & ESTADO_INVISIBLE) != 0; } }
        public bool Deshabilitado { get { return (Estado & ESTADO_NO_DISPONIBLE) != 0; } }
        public override string ToString()
        {
            return new string(' ', Profundidad * 2) + "rol=" + Rol + " nombre='" + Nombre + "' estado=0x" + Estado.ToString("X") + " rect=" + X + "," + Y + "," + W + "," + H;
        }
    }

    public static class Ui
    {
        [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr h, uint id, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IAccessible o);
        [DllImport("oleacc.dll")] static extern int AccessibleChildren(IAccessible p, int start, int n, [Out] object[] arr, out int got);
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool f);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] i, int size);

        [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Explicit)] struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
        [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTUNION u; }
        const uint INPUT_KEYBOARD = 1, KEYEVENTF_KEYUP = 2, KEYEVENTF_UNICODE = 4;

        static readonly Guid IID_IAccessible = new Guid("618736e0-3c3d-11cf-810c-00aa00389b71");
        const uint OBJID_CLIENT = 0xFFFFFFFC;

        /// Ventana principal visible de la consola (clase Chrome_WidgetWin_1 del proceso FortiClient).
        public static IntPtr VentanaConsola(int[] pids)
        {
            IntPtr r = IntPtr.Zero;
            var set = new HashSet<uint>();
            foreach (var p in pids) set.Add((uint)p);
            EnumWindows((h, l) =>
            {
                uint pid; GetWindowThreadProcessId(h, out pid);
                if (!set.Contains(pid)) return true;
                var c = new StringBuilder(256); GetClassName(h, c, 256);
                var t = new StringBuilder(512); GetWindowText(h, t, 512);
                if (c.ToString() == "Chrome_WidgetWin_1" && t.ToString().StartsWith("FortiClient") && IsWindowVisible(h)) { r = h; return false; }
                return true;
            }, IntPtr.Zero);
            return r;
        }

        public static IntPtr VentanaWeb(IntPtr top)
        {
            IntPtr r = IntPtr.Zero;
            EnumChildWindows(top, (h, l) =>
            {
                var s = new StringBuilder(256); GetClassName(h, s, 256);
                if (s.ToString() == "Chrome_RenderWidgetHostHWND") { r = h; return false; }
                return true;
            }, IntPtr.Zero);
            return r;
        }

        /// Pedir el objeto MSAA activa la accesibilidad de Chromium (sin ello el árbol UIA
        /// solo tiene 3 nodos). La ventana Chrome_RenderWidgetHostHWND no siempre existe:
        /// si falta, se pide a la ventana principal, que también responde y la crea.
        public static List<Nodo> Arbol(IntPtr top)
        {
            var lista = new List<Nodo>();
            IntPtr web = VentanaWeb(top);
            Guid g = IID_IAccessible; IAccessible raiz;
            if (web == IntPtr.Zero || AccessibleObjectFromWindow(web, OBJID_CLIENT, ref g, out raiz) != 0 || raiz == null)
            {
                g = IID_IAccessible;
                if (AccessibleObjectFromWindow(top, OBJID_CLIENT, ref g, out raiz) != 0 || raiz == null) return lista;
            }
            Recorrer(raiz, 0, lista);
            return lista;
        }

        static string Seguro(Func<string> f) { try { return f() ?? ""; } catch { return ""; } }

        static void Recorrer(IAccessible a, int d, List<Nodo> lista)
        {
            if (d > 60) return;
            lista.Add(Crear(a, 0, d));
            int n = 0; try { n = a.accChildCount; } catch { }
            if (n <= 0) return;
            var arr = new object[n]; int got;
            if (AccessibleChildren(a, 0, n, arr, out got) != 0) return;
            for (int i = 0; i < got; i++)
            {
                var c = arr[i] as IAccessible;
                if (c != null) Recorrer(c, d + 1, lista);
                else if (arr[i] is int) lista.Add(Crear(a, (int)arr[i], d + 1));
            }
        }

        static Nodo Crear(IAccessible a, object hijo, int d)
        {
            var n = new Nodo { Acc = a, Hijo = hijo, Profundidad = d };
            try { n.Rol = Convert.ToInt32(a.get_accRole(hijo)); } catch { n.Rol = -1; }
            n.Nombre = Seguro(() => a.get_accName(hijo)).Trim();
            try { n.Estado = Convert.ToInt32(a.get_accState(hijo)); } catch { }
            try { a.accLocation(out n.X, out n.Y, out n.W, out n.H, hijo); } catch { }
            return n;
        }

        /// Valor de un nodo no protegido (nunca devuelve el de un campo de contraseña).
        public static string Valor(Nodo n)
        {
            if (n.Protegido) return null;
            return Seguro(() => n.Acc.get_accValue(n.Hijo));
        }

        /// Longitud del contenido de un campo protegido (Chromium devuelve viñetas), sin revelar el contenido.
        public static int LongitudProtegido(Nodo n)
        {
            string v = Seguro(() => n.Acc.get_accValue(n.Hijo));
            return v.Length;
        }

        public static bool Enfocar(Nodo n)
        {
            try { n.Acc.accSelect(1 /* SELFLAG_TAKEFOCUS */, n.Hijo); return true; } catch { return false; }
        }

        public static bool AccionPorDefecto(Nodo n)
        {
            try { n.Acc.accDoDefaultAction(n.Hijo); return true; } catch { return false; }
        }

        public static bool PonerValor(Nodo n, string v)
        {
            try { n.Acc.set_accValue(n.Hijo, v); return true; } catch { return false; }
        }

        public static bool EstaEnfocado(Nodo n)
        {
            try { return (Convert.ToInt32(n.Acc.get_accState(n.Hijo)) & Nodo.ESTADO_ENFOCADO) != 0; } catch { return false; }
        }

        /// Trae la ventana al frente sin pulsar Alt (Alt activaría la barra de menús de FortiClient).
        public static bool AlFrente(IntPtr h)
        {
            if (GetForegroundWindow() == h) return true;
            if (IsIconic(h)) ShowWindow(h, 9);
            uint pid;
            uint fg = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
            uint yo = GetCurrentThreadId();
            bool unido = fg != yo && AttachThreadInput(yo, fg, true);
            try { BringWindowToTop(h); SetForegroundWindow(h); ShowWindow(h, 5); }
            finally { if (unido) AttachThreadInput(yo, fg, false); }
            for (int i = 0; i < 20 && GetForegroundWindow() != h; i++) Thread.Sleep(50);
            if (GetForegroundWindow() != h)
            {
                // Último recurso: minimizar y restaurar suele conceder el primer plano.
                ShowWindow(h, 6); Thread.Sleep(150); ShowWindow(h, 9);
                for (int i = 0; i < 20 && GetForegroundWindow() != h; i++) Thread.Sleep(50);
            }
            return GetForegroundWindow() == h;
        }

        static bool Enviar(INPUT[] ins) { return SendInput((uint)ins.Length, ins, Marshal.SizeOf(typeof(INPUT))) == ins.Length; }

        static INPUT Tecla(ushort vk, ushort scan, uint flags)
        {
            var i = new INPUT { type = INPUT_KEYBOARD };
            i.u.ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags };
            return i;
        }

        static bool Caracter(IntPtr h, char c)
        {
            if (GetForegroundWindow() != h) return false; // nunca teclear en otra ventana
            return Enviar(new[] { Tecla(0, c, KEYEVENTF_UNICODE), Tecla(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP) });
        }

        /// Teclea un texto no secreto (usuario, nombre del túnel, PIN). Devuelve false si la ventana pierde el primer plano.
        public static bool Escribir(IntPtr h, string texto)
        {
            foreach (char c in texto) { if (!Caracter(h, c)) return false; Thread.Sleep(15); }
            return true;
        }

        /// Pulsa una tecla virtual, opcionalmente con Ctrl (p. ej. Ctrl+A, Supr, Intro).
        public static bool Pulsar(IntPtr h, ushort vk, bool ctrl)
        {
            if (GetForegroundWindow() != h) return false;
            var l = new List<INPUT>();
            if (ctrl) l.Add(Tecla(0x11, 0, 0));
            l.Add(Tecla(vk, 0, 0)); l.Add(Tecla(vk, 0, KEYEVENTF_KEYUP));
            if (ctrl) l.Add(Tecla(0x11, 0, KEYEVENTF_KEYUP));
            bool ok = Enviar(l.ToArray()); Thread.Sleep(40); return ok;
        }

        /// Vacía el campo enfocado (Ctrl+A y Supr).
        public static bool Vaciar(IntPtr h) { return Pulsar(h, 0x41, true) && Pulsar(h, 0x2E, false); }

        /// Teclea la contraseña de una credencial genérica directamente desde el blob nativo.
        /// Devuelve el número de caracteres tecleados, -1 si no existe la credencial, -2 si se perdió el primer plano.
        public static int EscribirSecreto(IntPtr h, string target)
        {
            IntPtr pc;
            if (!Cred.CredRead(target, Cred.CRED_TYPE_GENERIC, 0, out pc)) return -1;
            try
            {
                var c = (Cred.CREDENTIAL)Marshal.PtrToStructure(pc, typeof(Cred.CREDENTIAL));
                int n = (int)c.CredentialBlobSize / 2;
                for (int i = 0; i < n; i++)
                {
                    char ch = (char)Marshal.ReadInt16(c.CredentialBlob, i * 2);
                    bool ok = Caracter(h, ch);
                    ch = '\0';
                    if (!ok) return -2;
                    Thread.Sleep(15);
                }
                return n;
            }
            finally { Cred.CredFree(pc); }
        }
    }

    public static class Cred
    {
        public const int CRED_TYPE_GENERIC = 1, CRED_TYPE_DOMAIN_PASSWORD = 2, CRED_PERSIST_LOCAL_MACHINE = 2;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct CREDENTIAL
        {
            public int Flags; public int Type; public string TargetName; public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist;
            public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CredRead(string target, int type, int flags, out IntPtr cred);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredWrite(ref CREDENTIAL cred, int flags);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredDelete(string target, int type, int flags);
        [DllImport("advapi32.dll")] public static extern void CredFree(IntPtr p);

        /// Usuario de una credencial (null si no existe). Vale también para las de dominio: el usuario sí se puede leer.
        public static string Usuario(string target, int tipo)
        {
            IntPtr pc;
            if (!CredRead(target, tipo, 0, out pc)) return null;
            try { return ((CREDENTIAL)Marshal.PtrToStructure(pc, typeof(CREDENTIAL))).UserName ?? ""; }
            finally { CredFree(pc); }
        }

        /// Longitud en caracteres de la contraseña guardada (para comprobar sin revelarla); -1 si no existe.
        public static int LongitudSecreto(string target, int tipo)
        {
            IntPtr pc;
            if (!CredRead(target, tipo, 0, out pc)) return -1;
            try { return ((CREDENTIAL)Marshal.PtrToStructure(pc, typeof(CREDENTIAL))).CredentialBlobSize / 2; }
            finally { CredFree(pc); }
        }

        /// Guarda una credencial genérica copiando la SecureString a memoria nativa, sin pasar por string.
        public static void Guardar(string target, string usuario, SecureString clave)
        {
            IntPtr p = Marshal.SecureStringToGlobalAllocUnicode(clave);
            try
            {
                var c = new CREDENTIAL
                {
                    Type = CRED_TYPE_GENERIC, TargetName = target, UserName = usuario,
                    CredentialBlob = p, CredentialBlobSize = clave.Length * 2,
                    Persist = CRED_PERSIST_LOCAL_MACHINE, Comment = "vpn-forti"
                };
                if (!CredWrite(ref c, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            finally { Marshal.ZeroFreeGlobalAllocUnicode(p); }
        }

        public static bool Borrar(string target, int tipo) { return CredDelete(target, tipo, 0); }
    }
}
