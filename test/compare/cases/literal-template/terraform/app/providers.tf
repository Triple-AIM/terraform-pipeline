# The same region as on the default branch. It is written as a template, but
# the template refers to nothing. So it is still a literal.
provider "aws" {
  region = "us-${"east"}-1"
}
