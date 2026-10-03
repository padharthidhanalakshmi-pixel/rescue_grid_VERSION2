import '../models/enums.dart';

/// General safety guidance shown to the student while help is on the way or
/// the incident is queued. Generic first-response advice, not medical advice.
List<String> safetyGuidance(IncidentCategory c) => switch (c) {
      IncidentCategory.medical => [
          'Stay with the person and keep them calm.',
          'Check if they are breathing. Do not give food or water.',
          'Do not move them unless the area is unsafe.',
          'Ask nearby staff or trained students for first aid.',
        ],
      IncidentCategory.fire => [
          'Move away from smoke and fire immediately.',
          'Use stairs, never lifts. Stay low under smoke.',
          'Alert people nearby and leave the building.',
          'Do not go back inside for belongings.',
        ],
      IncidentCategory.security => [
          'Move to a safe, crowded, well-lit place.',
          'Do not confront the person.',
          'Note what you saw: description, direction, time.',
          'Lock yourself in a room if you cannot leave safely.',
        ],
      IncidentCategory.electrical => [
          'Do not touch wires, panels or anyone in contact with them.',
          'Keep everyone at a safe distance.',
          'Never use water on electrical sparks or fire.',
        ],
      IncidentCategory.accident => [
          'Make the area safe; warn approaching vehicles.',
          'Do not move an injured person unless there is danger.',
          'Apply firm pressure to bleeding with a clean cloth.',
        ],
      IncidentCategory.flooding => [
          'Move away from water near electrical points.',
          'Move to higher ground; avoid walking through water.',
          'Keep others away from the area.',
        ],
      IncidentCategory.chemical => [
          'Leave the area and move upwind to fresh air.',
          'Do not touch or smell the substance.',
          'Wash skin or eyes with clean water if exposed.',
        ],
      IncidentCategory.other => [
          'Move to a safe place and stay calm.',
          'Keep your phone with you for updates.',
          'Follow instructions from campus staff.',
        ],
    };

/// External services the command center can call when everyone is busy.
/// Numbers are India's public emergency numbers; the campus security number
/// must be entered by LBRCE in Settings (not invented here).
class ExternalContact {
  ExternalContact(this.name, this.number);
  String name;
  String number;
}

List<ExternalContact> defaultExternalContacts() => [
      ExternalContact('LBRCE Campus Security', ''),
      ExternalContact('Ambulance', '108'),
      ExternalContact('National Emergency', '112'),
      ExternalContact('Fire Service', '101'),
      ExternalContact('Police', '100'),
    ];
