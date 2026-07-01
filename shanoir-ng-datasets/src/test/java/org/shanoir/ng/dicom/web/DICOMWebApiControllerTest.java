/**
 * Shanoir NG - Import, manage and share neuroimaging data
 * Copyright (C) 2009-2019 Inria - https://www.inria.fr/
 * Contact us on https://project.inria.fr/shanoir/
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see https://www.gnu.org/licenses/gpl-3.0.html
 */

package org.shanoir.ng.dicom.web;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.BDDMockito.given;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import org.shanoir.ng.datasetacquisition.service.DatasetAcquisitionService;
import org.shanoir.ng.dicom.web.service.DICOMWebService;
import org.shanoir.ng.examination.model.Examination;
import org.shanoir.ng.examination.service.ExaminationService;
import org.shanoir.ng.importer.service.DicomImporterService;
import org.shanoir.ng.importer.service.DicomSEGAndSRImporterService;
import org.shanoir.ng.utils.usermock.WithMockKeycloakUser;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.data.web.config.EnableSpringDataWebSupport;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.ContextConfiguration;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders;

@WebMvcTest(controllers = DICOMWebApiController.class)
@AutoConfigureMockMvc(addFilters = false)
@ContextConfiguration()
@EnableSpringDataWebSupport
@ActiveProfiles("test")
public class DICOMWebApiControllerTest {

    private static final String REQUEST_PATH = "/dicomweb/studies";

    @Autowired
    private MockMvc mvc;

    @MockBean
    private ExaminationService examinationServiceMock;

    @MockBean
    private DatasetAcquisitionService datasetAcquisitionServiceMock;

    @MockBean
    private DICOMWebService dicomWebServiceMock;

    @MockBean
    private StudyInstanceUIDAndSubjectNameHandler studyInstanceUIDAndSubjectNameHandlerMock;

    @MockBean
    private SeriesInstanceUIDHandler seriesInstanceUIDHandlerMock;

    @MockBean
    private DicomSEGAndSRImporterService dicomSEGAndSRImporterServiceMock;

    @MockBean
    private DicomImporterService dicomImporterServiceMock;

    @BeforeEach
    public void setup() {
        Examination exam1 = new Examination();
        exam1.setId(1L);
        Examination exam2 = new Examination();
        exam2.setId(2L);
        given(examinationServiceMock.findById(1L)).willReturn(exam1);
        given(examinationServiceMock.findById(2L)).willReturn(exam2);

        given(studyInstanceUIDAndSubjectNameHandlerMock
                .findStudyInstanceUIDFromCacheOrDatabase(StudyInstanceUIDAndSubjectNameHandler.PREFIX + "1"))
                .willReturn("1.2.3.1");
        given(studyInstanceUIDAndSubjectNameHandlerMock
                .findStudyInstanceUIDFromCacheOrDatabase(StudyInstanceUIDAndSubjectNameHandler.PREFIX + "2"))
                .willReturn("1.2.3.2");
        given(studyInstanceUIDAndSubjectNameHandlerMock.findSubjectNameFromCacheOrDatabase(anyString()))
                .willReturn("subject");

        given(dicomWebServiceMock.findStudy(anyString(), Mockito.nullable(String.class))).willReturn("[{\"foo\":\"bar\"}]");
    }

    @Test
    @WithMockKeycloakUser(id = 12, username = "test", authorities = { "ROLE_ADMIN" })
    public void findStudiesWithSeveralCommaSeparatedStudyInstanceUIDsReturnsAllExaminations() throws Exception {
        mvc.perform(MockMvcRequestBuilders.get(REQUEST_PATH)
                .param("StudyInstanceUID", "1.4.9.12.34.1.8527.1,1.4.9.12.34.1.8527.2")
                .param("offset", "0")
                .param("limit", "10")
                .accept("application/dicom+json"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.length()").value(2));

        Mockito.verify(examinationServiceMock).findById(1L);
        Mockito.verify(examinationServiceMock).findById(2L);
    }

}
