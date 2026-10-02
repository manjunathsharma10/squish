// WPF projects leave System.IO out of the implicit usings (Path clashes with
// System.Windows.Shapes.Path); the engines and model need it.
global using System.IO;
