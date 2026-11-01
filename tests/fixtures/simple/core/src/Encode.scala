package example

object Encode {
  def numbers(xs: Seq[Int]): String = upickle.default.write(xs)

  def main(args: Array[String]): Unit = println(numbers(Seq(1, 2)))
}
