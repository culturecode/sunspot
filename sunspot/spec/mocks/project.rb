class Milestone < MockRecord
  attr_accessor :name, :started_at, :finished_at, :due_at, :owner_names
end

class Project < MockRecord
  attr_accessor :name, :status
  attr_writer :milestones, :reviews

  def milestones
    @milestones ||= []
  end

  # Children that have no adapter of their own
  def reviews
    @reviews ||= []
  end
end

Sunspot.setup(Project) do
  string :name
  string :status

  nested :milestones do
    string :name
    time :started_at
    time :finished_at
    time :due_at
    string :owner_names, :multiple => true
    integer(:days_late) { finished_at && due_at && finished_at > due_at ? ((finished_at - due_at) / 86_400).to_i : 0 }
  end

  nested :reviews do
    string :verdict
  end
end

# Another class sharing a field name with the children
class Memo < MockRecord
  attr_accessor :name
end

Sunspot.setup(Memo) do
  string :name
end

# A subclass that declares the same association again
class SubProject < Project
end

Sunspot.setup(SubProject) do
  nested :milestones do
    string :name
  end
end

# An unrelated class with an association of the same name
class Program < MockRecord
  attr_accessor :name
  attr_writer :milestones

  def milestones
    @milestones ||= []
  end
end

Sunspot.setup(Program) do
  string :name

  nested :milestones do
    string :name
  end
end

# A superclass with no nested associations, and a subclass that has one
class Asset < MockRecord
  attr_accessor :name
end

Sunspot.setup(Asset) do
  string :name
end

class Vehicle < Asset
  attr_writer :parts

  def parts
    @parts ||= []
  end
end

Sunspot.setup(Vehicle) do
  nested :parts do
    string :name
  end
end
