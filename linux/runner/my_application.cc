#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

// the window's size on opening and the smallest it can be made, in logical pixels as on the Mac and Windows
static constexpr int kWidth = 1320, kHeight = 820, kMinWidth = 1100, kMinHeight = 640;
static constexpr char kTitle[] = "GeoRivView Replay";

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  FlMethodChannel* window_channel;
  // with OPRIVVIEW_JOB set the replay server has started this to render a clip: it draws off screen and shows nothing
  gboolean hidden;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  if (!self->hidden) gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// the computer's own save and folder pickers (through the desktop's portal where there is one), as the Mac uses its own
// through osascript and Windows its own in flutter_window.cpp. The save picker asks before replacing a file. Nothing
// chosen gives no value.
static FlValue* choose_file(GtkWindow* owner, gboolean folder, const gchar* name) {
  GtkFileChooserNative* dialog = gtk_file_chooser_native_new(
      folder ? "Save clips in" : "Save the MP4 as", owner,
      folder ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER : GTK_FILE_CHOOSER_ACTION_SAVE, folder ? "Choose" : "Save", "Cancel");
  GtkFileChooser* chooser = GTK_FILE_CHOOSER(dialog);
  // start in Videos, where a clip goes when no file is chosen
  const gchar* videos = g_get_user_special_dir(G_USER_DIRECTORY_VIDEOS);
  if (videos != nullptr) gtk_file_chooser_set_current_folder(chooser, videos);
  if (!folder) {
    gtk_file_chooser_set_do_overwrite_confirmation(chooser, TRUE);
    GtkFileFilter* mp4 = gtk_file_filter_new();
    gtk_file_filter_set_name(mp4, "MP4 video");
    gtk_file_filter_add_pattern(mp4, "*.mp4");
    gtk_file_chooser_add_filter(chooser, mp4);
    if (name != nullptr) gtk_file_chooser_set_current_name(chooser, name);
  }
  FlValue* chosen = nullptr;
  if (gtk_native_dialog_run(GTK_NATIVE_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
    g_autofree gchar* path = gtk_file_chooser_get_filename(chooser);
    if (path != nullptr) chosen = fl_value_new_string(path);
  }
  g_object_unref(dialog);
  return chosen != nullptr ? chosen : fl_value_new_null();
}

// lets the preview take over the whole screen (Esc in the preview turns it off again through the same call), and opens
// the computer's own save and folder pickers; the same calls as the Windows window answers
static void window_call_cb(FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "setFullScreen") == 0) {
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
      if (fl_value_get_bool(args)) {
        gtk_window_fullscreen(self->window);
      } else {
        gtk_window_unfullscreen(self->window);
      }
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "chooseSaveFile") == 0 || g_strcmp0(method, "chooseFolder") == 0) {
    const gchar* name =
        args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_STRING ? fl_value_get_string(args) : nullptr;
    g_autoptr(FlValue) chosen = choose_file(self->window, g_strcmp0(method, "chooseFolder") == 0, name);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(chosen));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  self->hidden = g_getenv("OPRIVVIEW_JOB") != nullptr;

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
    gtk_header_bar_set_title(header_bar, kTitle);
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, kTitle);
  }

  gtk_window_set_default_size(window, kWidth, kHeight);
  GdkGeometry smallest = {};
  smallest.min_width = kMinWidth;
  smallest.min_height = kMinHeight;
  gtk_window_set_geometry_hints(window, nullptr, &smallest, GDK_HINT_MIN_SIZE);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_channel = fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)),
                                               "oprivview/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->window_channel, window_call_cb, self, nullptr);

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
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_channel);
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

  // not unique: the replay server starts more copies of this program to render clips while the window is open
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
