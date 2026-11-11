defmodule Sismo.Users.Permissions do
  @moduledoc "Matriz rol → acciones. Cada rol hereda las del anterior."

  @citizen ~w(register_need list_needs report_person find_person send_family_message
              list_family_messages report_pet list_resources check_shelter
              zone_status list_pets activity)a
  @volunteer @citizen ++ ~w(register_resource register_entry register_exit match_pets pending_needs
                            person_status mark_message)a
  @coordinator @volunteer ++ ~w(register_zone assign_resource transfer_resource register_shelter
                                summary critical_resources update_need confirm_match)a
  @admin @coordinator ++ ~w(manage_users)a

  @by_role %{
    ciudadano: @citizen,
    voluntario: @volunteer,
    coordinador: @coordinator,
    administrador: @admin
  }

  @spec can?(atom(), atom()) :: boolean()
  def can?(role, action), do: action in Map.get(@by_role, role, [])
end
