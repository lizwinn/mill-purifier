package example;

import androidx.annotation.NonNull;
import com.google.common.base.Joiner;

public final class Greeter {
  private Greeter() {}

  @NonNull
  public static String greet(String... names) {
    return "hello " + Joiner.on(", ").join(names);
  }
}
