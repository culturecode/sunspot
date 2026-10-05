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
