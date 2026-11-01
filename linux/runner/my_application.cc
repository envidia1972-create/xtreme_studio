#include "my_application.h"

#include <initializer_list>

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Carga el icono de la app desde el bundle (data/app_icon.png).
//
// Se calcula la ruta a partir de /proc/self/exe para que funcione aunque la
// carpeta se abra desde otro directorio. Si el archivo no existe (por ejemplo,
// al ejecutar el binario sin instalar), no pasa nada.
static void set_window_icon(GtkWindow* window) {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) return;

  g_autofree gchar* dir = g_path_get_dirname(exe);
  g_autofree gchar* icon =
      g_build_filename(dir, "data", "app_icon.png", nullptr);
  if (!g_file_test(icon, G_FILE_TEST_EXISTS)) return;

  g_autoptr(GError) error = nullptr;
  g_autoptr(GdkPixbuf) source = gdk_pixbuf_new_from_file(icon, &error);
  if (source == nullptr) {
    g_printerr("Xtreme Studio: no se pudo cargar el icono %s: %s\n", icon,
               error != nullptr ? error->message : "error desconocido");
    return;
  }

  // Se pasan varios tamanos: el escritorio elige el que necesita y GTK publica
  // `_NET_WM_ICON` (el icono que usan las barras de tareas modernas).
  GList* icons = nullptr;
  for (const int size : {16, 24, 32, 48, 64, 128, 256}) {
    GdkPixbuf* scaled = gdk_pixbuf_scale_simple(
        source, size, size, GDK_INTERP_BILINEAR);
    if (scaled != nullptr) icons = g_list_append(icons, scaled);
  }
  gtk_window_set_icon_list(window, icons);
  gtk_window_set_default_icon_list(icons);
  for (GList* item = icons; item != nullptr; item = item->next) {
    g_object_unref(item->data);
  }
  g_list_free(icons);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Xtreme Studio");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Xtreme Studio");
  }

  // La consola necesita ancho para la barra lateral y los vumetros. La ventana
  // se puede redimensionar; este es solo el tamano inicial comodo en cabina.
  // El tamano se recorta al area util del monitor: en pantallas de 1366x768
  // (portatiles de cabina) una ventana de 800 px de alto se sale por abajo y
  // deja el pie de la interfaz fuera de alcance.
  gint window_width = 1280;
  gint window_height = 800;
  GdkDisplay* display = gdk_display_get_default();
  if (display != nullptr) {
    GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
    if (monitor == nullptr) {
      GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
      if (gdk_window != nullptr) {
        monitor = gdk_display_get_monitor_at_window(display, gdk_window);
      }
    }
    if (monitor == nullptr) {
      monitor = gdk_display_get_monitor(display, 0);
    }
    if (monitor != nullptr) {
      GdkRectangle workarea = {0, 0, 0, 0};
      gdk_monitor_get_workarea(monitor, &workarea);
      if (workarea.width > 0 && workarea.height > 0) {
        window_width = MIN(window_width, workarea.width - 48);
        window_height = MIN(window_height, workarea.height - 48);
        if (window_width < 640) {
          window_width = workarea.width;
        }
        if (window_height < 480) {
          window_height = workarea.height;
        }
      }
    }
  }
  gtk_window_set_default_size(window, window_width, window_height);
  gtk_window_set_position(window, GTK_WIN_POS_CENTER);

  // Por debajo de este tamano la barra lateral, los vumetros y los botones de
  // emision se pisan. El minimo nunca supera el tamano inicial calculado.
  GdkGeometry geometry;
  geometry.min_width = MIN(960, window_width);
  geometry.min_height = MIN(600, window_height);
  gtk_window_set_geometry_hints(window, nullptr, &geometry, GDK_HINT_MIN_SIZE);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#0D0F14");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));
  set_window_icon(window);

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
